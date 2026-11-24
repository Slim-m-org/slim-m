// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting what a module's data store holds about one member (the contract is
//! in `docs/modules/reactive-modules.md`): every
//! text column the manifest marks `member` is matched against the account's id.

use std::time::{Duration, Instant};

use serde_json::json;

use super::data::{DataBackend, DataError};
use super::data_sql::{self, Statement};

/// Long enough for a large table, short enough that deletion never hangs on one module.
const PURGE_BUDGET: Duration = Duration::from_secs(5);
/// Rows one delete statement may remove, so module calls get the file between chunks.
const PURGE_CHUNK: u64 = 500;

/// Deletes the rows of `module_id` that name `user_id` in a member column; returns how many.
/// A statement that fails does not stop the rest, so one busy table leaves the others purged;
/// the first failure is returned once every column has been tried.
pub fn purge_member(
    backend: &dyn DataBackend,
    module_id: &str,
    user_id: &str,
) -> Result<u64, DataError> {
    let schema = match backend.schema(module_id) {
        Ok(schema) => schema,
        Err(DataError::NoSchema) => return Ok(0),
        Err(err) => return Err(err),
    };
    let purge = |table: &str, column: &str| -> Result<u64, DataError> {
        let request = json!({
            "op": "delete",
            "table": table,
            "where": [{ "col": column, "op": "eq", "val": user_id }],
        });
        let bytes = serde_json::to_vec(&request).map_err(|_| DataError::Unavailable)?;
        let statement = data_sql::build(&schema, &bytes).map_err(|_| DataError::Unavailable)?;
        let table = data_sql::quote(table);
        let rest = statement
            .sql
            .strip_prefix(&format!("DELETE FROM {table}"))
            .ok_or(DataError::Unavailable)?;
        let chunk = Statement {
            sql: format!(
                "DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table}{rest} LIMIT {PURGE_CHUNK})"
            ),
            ..statement
        };
        let started = Instant::now();
        let mut removed = 0;
        loop {
            let left = PURGE_BUDGET.saturating_sub(started.elapsed());
            if left.is_zero() {
                return Err(DataError::TooSlow);
            }
            let changed = backend.execute(module_id, &chunk, left)?.changed;
            removed += changed;
            if changed < PURGE_CHUNK {
                return Ok(removed);
            }
        }
    };
    let mut removed = 0;
    let mut failure = None;
    for table in &schema.tables {
        for column in table.columns.iter().filter(|c| c.member) {
            match purge(&table.name, &column.name) {
                Ok(changed) => removed += changed,
                Err(err) => failure = failure.or(Some(err)),
            }
        }
    }
    failure.map_or(Ok(removed), Err)
}
