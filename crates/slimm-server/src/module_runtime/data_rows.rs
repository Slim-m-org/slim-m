// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading a statement's rows into JSON maps while counting the bytes of the
//! reply they will become, so an oversized result is refused before it is built.

use futures_util::TryStreamExt;
use serde_json::{Map, Value};
use sqlx::query::Query;
use sqlx::sqlite::SqliteArguments;
use sqlx::sqlite::{Sqlite, SqliteRow};
use sqlx::{Row, SqlitePool};

use super::data::DataError;
use super::data_schema::ColumnType;
use super::limits::MAX_RESPONSE_BYTES;

/// What to do with the rows past the reply cap.
#[derive(Clone, Copy)]
pub(super) enum Overflow {
    /// Refuse the whole read; nothing it would have returned has happened yet.
    Refuse,
    /// Keep counting, but drop the rows; the write behind them already happened.
    Drop,
}

/// Every row of `query`, decoded, and how many there were.
pub(super) async fn read_rows(
    query: Query<'_, Sqlite, SqliteArguments>,
    pool: &SqlitePool,
    columns: &[(String, ColumnType)],
    overflow: Overflow,
) -> Result<(Vec<Map<String, Value>>, u64), DataError> {
    let mut stream = query.fetch(pool);
    let (mut rows, mut seen, mut bytes) = (Vec::new(), 0_u64, 0_usize);
    while let Some(row) = stream
        .try_next()
        .await
        .map_err(|e| super::data_sqlite::classify(&e))?
    {
        seen += 1;
        if bytes > MAX_RESPONSE_BYTES {
            if matches!(overflow, Overflow::Refuse) {
                return Err(DataError::TooLarge);
            }
            continue;
        }
        let decoded = decode_row(&row, columns)?;
        bytes += serde_json::to_vec(&decoded).map_or(usize::MAX, |b| b.len());
        if bytes > MAX_RESPONSE_BYTES {
            if matches!(overflow, Overflow::Refuse) {
                return Err(DataError::TooLarge);
            }
            continue;
        }
        rows.push(decoded);
    }
    Ok((rows, seen))
}

pub(super) fn decode_row(
    row: &SqliteRow,
    columns: &[(String, ColumnType)],
) -> Result<Map<String, Value>, DataError> {
    let mut out = Map::new();
    for (i, (name, ty)) in columns.iter().enumerate() {
        out.insert(name.clone(), decode(row, i, *ty)?);
    }
    Ok(out)
}

fn decode(row: &SqliteRow, index: usize, ty: ColumnType) -> Result<Value, DataError> {
    let bad = |_| DataError::Unavailable;
    Ok(match ty {
        ColumnType::Int => row.try_get::<Option<i64>, _>(index).map_err(bad)?.into(),
        ColumnType::Real => match row.try_get::<Option<f64>, _>(index).map_err(bad)? {
            None => Value::Null,
            Some(x) => {
                Value::Number(serde_json::Number::from_f64(x).ok_or(DataError::Unavailable)?)
            }
        },
        ColumnType::Text => row.try_get::<Option<String>, _>(index).map_err(bad)?.into(),
        ColumnType::Bool => row
            .try_get::<Option<i64>, _>(index)
            .map_err(bad)?
            .map_or(Value::Null, |n| Value::Bool(n != 0)),
    })
}

pub(super) fn decode_scalar(row: &SqliteRow, ty: ColumnType) -> Result<Value, DataError> {
    decode(row, 0, ty)
}
