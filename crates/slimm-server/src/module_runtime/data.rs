// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `data.store` (decision 0091): a small structured store private to one
//! module. The host builds every statement from the module's declared schema
//! ([`super::data_sql`]); a [`DataBackend`] only runs what it is handed, against
//! that module's own file. Every path fails closed with `{ok:false,error}`.

use serde_json::{Map, Value, json};

use super::data_schema::DataSchema;
use super::data_sql::{self, Shape, Statement};

/// Why a backend could not run a statement.
#[derive(Debug)]
pub enum DataError {
    /// The module's file reached its cap.
    Full,
    /// A unique column already holds that value.
    Conflict,
    /// The module has declared no data.
    NoSchema,
    /// The store failed; the module sees a refusal, never the cause.
    Unavailable,
}

/// What a statement produced; the handler shapes it into the reply.
#[derive(Debug, Default)]
pub struct Outcome {
    pub rows: Vec<Map<String, Value>>,
    pub changed: u64,
    pub scalar: Option<Value>,
}

/// Where a module's tables live, one file per module so none can reach another.
pub trait DataBackend: Send + Sync {
    /// The schema the module's file was last migrated to.
    fn schema(&self, module_id: &str) -> Result<DataSchema, DataError>;
    fn execute(&self, module_id: &str, statement: &Statement) -> Result<Outcome, DataError>;
}

/// Dispatches one `data.store` request for `module_id`, spending one call of
/// the run's budget shared with `kv.store`.
pub fn handle(
    backend: &dyn DataBackend,
    module_id: &str,
    calls_remaining: &mut u32,
    request: &[u8],
) -> Vec<u8> {
    if *calls_remaining == 0 {
        return refusal("data.store call budget for this run is exhausted");
    }
    *calls_remaining -= 1;
    let schema = match backend.schema(module_id) {
        Ok(schema) => schema,
        Err(err) => return refusal(error_text(&err)),
    };
    let statement = match data_sql::build(&schema, request) {
        Ok(statement) => statement,
        Err(message) => return refusal(&message),
    };
    match backend.execute(module_id, &statement) {
        Ok(outcome) => reply(&statement.shape, outcome),
        Err(err) => refusal(error_text(&err)),
    }
}

fn error_text(err: &DataError) -> &'static str {
    match err {
        DataError::Full => "data.store is full for this module",
        DataError::Conflict => "a unique column already holds that value",
        DataError::NoSchema => "this module declared no data",
        DataError::Unavailable => "data.store is unavailable",
    }
}

/// A `count` or `sum` carries its number in `count`.
fn reply(shape: &Shape, outcome: Outcome) -> Vec<u8> {
    let mut body = json!({
        "ok": true,
        "rows": outcome.rows,
        "changed": outcome.changed,
        "count": outcome.rows.len(),
    });
    if let (Shape::Scalar(_), Some(value)) = (shape, outcome.scalar) {
        body["count"] = value;
    }
    serde_json::to_vec(&body).unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

fn refusal(message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "ok": false, "error": message }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}
