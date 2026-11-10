// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting what a module's data store holds about one member (the contract is
//! in `docs/modules/reactive-modules.md`): every
//! text column the manifest marks `member` is matched against the account's id.

use std::time::Duration;

use serde_json::json;

use super::data::{DataBackend, DataError};
use super::data_sql;

/// Long enough for a large table, short enough that deletion never hangs on one module.
const PURGE_BUDGET: Duration = Duration::from_secs(5);

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
        Ok(backend
            .execute(module_id, &statement, PURGE_BUDGET)?
            .changed)
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
