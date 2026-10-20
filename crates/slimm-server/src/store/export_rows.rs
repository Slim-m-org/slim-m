// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading rows for an export one at a time, so no export ever holds a table
//! in memory.
//!
//! A query names its output columns and this module turns each row into a JSON
//! object: a 16-byte blob is a UUID, a column named `is_*` or `has_*` is a
//! boolean, and a column ending `_json` holds JSON text that is parsed and
//! nested under the name without the suffix.

use serde_json::{Map, Value};
use sqlx::sqlite::SqliteRow;
use sqlx::{Column, Row, TypeInfo, ValueRef};
use tokio::sync::mpsc;
use uuid::Uuid;

use super::Store;

/// Rows buffered between the database reader and the file writer.
const ROW_BUFFER: usize = 256;

/// Rows of one query, ended by the channel closing or by one error.
pub type RowStream = mpsc::Receiver<anyhow::Result<Value>>;

impl Store {
    /// Runs `sql` with `?1` bound to `id` and streams its rows as JSON.
    pub(super) fn stream_rows(&self, sql: &'static str, id: Uuid) -> RowStream {
        let pool = self.pool.clone();
        let (tx, rx) = mpsc::channel(ROW_BUFFER);
        tokio::spawn(async move {
            use futures_util::StreamExt;
            let mut rows = sqlx::query(sql).bind(id).fetch(&pool);
            while let Some(row) = rows.next().await {
                let item = row
                    .map_err(anyhow::Error::from)
                    .and_then(|r| row_to_json(&r));
                let failed = item.is_err();
                if tx.send(item).await.is_err() || failed {
                    break;
                }
            }
        });
        rx
    }

    /// The single row of `sql` (bound as in [`Store::stream_rows`]), if any.
    pub(super) async fn one_row(
        &self,
        sql: &'static str,
        id: Uuid,
    ) -> anyhow::Result<Option<Value>> {
        let row = sqlx::query(sql).bind(id).fetch_optional(&self.pool).await?;
        row.as_ref().map(row_to_json).transpose()
    }

    /// The first column of the first row of `sql`, as a count.
    pub(super) async fn count_rows(&self, sql: &'static str, id: Uuid) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar(sql)
            .bind(id)
            .fetch_one(&self.pool)
            .await?)
    }
}

fn row_to_json(row: &SqliteRow) -> anyhow::Result<Value> {
    let mut object = Map::new();
    for (index, column) in row.columns().iter().enumerate() {
        let name = column.name();
        let raw = row.try_get_raw(index)?;
        let value = if raw.is_null() {
            Value::Null
        } else {
            match raw.type_info().name() {
                "INTEGER" => {
                    let number: i64 = row.try_get(index)?;
                    if name.starts_with("is_") || name.starts_with("has_") {
                        Value::Bool(number != 0)
                    } else {
                        Value::from(number)
                    }
                }
                "REAL" => Value::from(row.try_get::<f64, _>(index)?),
                "BLOB" => blob_value(&row.try_get::<Vec<u8>, _>(index)?),
                _ => Value::String(row.try_get::<String, _>(index)?),
            }
        };
        match name.strip_suffix("_json") {
            Some(stem) => {
                let parsed = match &value {
                    Value::String(text) => serde_json::from_str(text)?,
                    other => other.clone(),
                };
                object.insert(stem.to_owned(), parsed);
            }
            None => {
                object.insert(name.to_owned(), value);
            }
        }
    }
    Ok(Value::Object(object))
}

fn blob_value(bytes: &[u8]) -> Value {
    match Uuid::from_slice(bytes) {
        Ok(id) => Value::String(id.to_string()),
        Err(_) => Value::String(crate::media::to_hex(bytes)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blob_that_is_not_a_uuid_becomes_hex() {
        assert_eq!(blob_value(&[0xab, 0xcd]), Value::String("abcd".into()));
        let id = Uuid::now_v7();
        assert_eq!(blob_value(id.as_bytes()), Value::String(id.to_string()));
    }
}
