// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Builds the one SQL statement a `data.store` request means. Identifiers come
//! only from the declared [`DataSchema`] and are quoted; every value is a bound
//! parameter, so module input is never part of the statement text.

use serde::Deserialize;
use serde_json::{Map, Value};

use super::data_schema::{ColumnType, DataSchema, Table};

/// Longest text value a module may store or compare, in bytes.
pub const MAX_TEXT_BYTES: usize = 4 * 1024;
/// Most rows one `query` returns.
pub const MAX_ROWS: i64 = 200;
const MAX_OFFSET: i64 = 1_000_000;
const MAX_CONDITIONS: usize = 16;
const MAX_IN_VALUES: usize = 100;
const MAX_ORDER: usize = 4;
const MAX_INCREMENT: i64 = 1 << 53;
const ID: &str = "_id";

#[derive(Debug, Clone, PartialEq)]
pub enum Bind {
    Int(i64),
    Real(f64),
    Text(String),
    Null,
}

/// What the statement returns, so the backend can shape the reply.
#[derive(Debug, Clone, PartialEq)]
pub enum Shape {
    /// Rows with these columns, `_id` first.
    Rows(Vec<(String, ColumnType)>),
    /// The id of the inserted row.
    Insert,
    /// Only the number of rows changed.
    Changed,
    /// A single number of this type.
    Scalar(ColumnType),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Statement {
    pub sql: String,
    pub binds: Vec<Bind>,
    pub shape: Shape,
}

#[derive(Deserialize)]
struct Request {
    op: String,
    table: String,
    #[serde(default)]
    values: Option<Map<String, Value>>,
    #[serde(default)]
    on: Option<Value>,
    #[serde(default, rename = "where")]
    filters: Vec<Condition>,
    #[serde(default)]
    order: Vec<Order>,
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
    #[serde(default)]
    col: Option<String>,
    #[serde(default)]
    by: Option<Value>,
}

#[derive(Deserialize)]
struct Condition {
    col: String,
    op: String,
    val: Value,
}

#[derive(Deserialize)]
struct Order {
    col: String,
    #[serde(default)]
    dir: Option<String>,
}

pub fn build(schema: &DataSchema, request: &[u8]) -> Result<Statement, String> {
    let req: Request =
        serde_json::from_slice(request).map_err(|_| "malformed data.store request".to_owned())?;
    let table = schema
        .table(&req.table)
        .ok_or_else(|| "unknown table".to_owned())?;
    let q = Quoted(&table.name);
    match req.op.as_str() {
        "insert" => insert(table, &q, &req),
        "upsert" => upsert(table, &q, &req),
        "update" => update(table, &q, &req),
        "delete" => delete(table, &q, &req),
        "get" => select(table, &q, &req, true),
        "query" => select(table, &q, &req, false),
        "count" => count(table, &q, &req),
        "sum" => sum(table, &q, &req),
        "increment" => increment(table, &q, &req),
        _ => Err("unknown data.store op".to_owned()),
    }
}

struct Quoted<'a>(&'a str);

fn quote(identifier: &str) -> String {
    format!("\"{identifier}\"")
}

fn column_type(table: &Table, name: &str) -> Result<ColumnType, String> {
    if name == ID {
        return Ok(ColumnType::Int);
    }
    table
        .column(name)
        .map(|c| c.ty)
        .ok_or_else(|| "unknown column".to_owned())
}

fn to_bind(ty: ColumnType, value: &Value) -> Result<Bind, String> {
    match (ty, value) {
        (_, Value::Null) => Ok(Bind::Null),
        (ColumnType::Int, Value::Number(n)) => n
            .as_i64()
            .map(Bind::Int)
            .ok_or_else(|| "value is not an integer".to_owned()),
        (ColumnType::Real, Value::Number(n)) => n
            .as_f64()
            .filter(|f| f.is_finite())
            .map(Bind::Real)
            .ok_or_else(|| "value is not a number".to_owned()),
        (ColumnType::Bool, Value::Bool(b)) => Ok(Bind::Int(i64::from(*b))),
        (ColumnType::Text, Value::String(s)) if s.len() <= MAX_TEXT_BYTES => {
            Ok(Bind::Text(s.clone()))
        }
        (ColumnType::Text, Value::String(_)) => Err("text value is too large".to_owned()),
        _ => Err("value does not match the column type".to_owned()),
    }
}

/// Column names and bound values of `values`, in a stable order.
fn assignments(table: &Table, values: &Map<String, Value>) -> Result<Vec<(String, Bind)>, String> {
    let mut out = Vec::new();
    for (name, value) in values {
        if name == ID {
            return Err("_id cannot be set".to_owned());
        }
        out.push((name.clone(), to_bind(column_type(table, name)?, value)?));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

fn required_values(req: &Request) -> Result<&Map<String, Value>, String> {
    req.values
        .as_ref()
        .ok_or_else(|| "this op needs values".to_owned())
}

fn insert_head(q: &Quoted, cols: &[(String, Bind)]) -> String {
    if cols.is_empty() {
        return format!("INSERT INTO {} DEFAULT VALUES", quote(q.0));
    }
    let names: Vec<String> = cols.iter().map(|c| quote(&c.0)).collect();
    let marks = vec!["?"; cols.len()].join(",");
    format!(
        "INSERT INTO {} ({}) VALUES ({marks})",
        quote(q.0),
        names.join(",")
    )
}

fn insert(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let cols = assignments(table, required_values(req)?)?;
    Ok(Statement {
        sql: insert_head(q, &cols),
        binds: cols.into_iter().map(|c| c.1).collect(),
        shape: Shape::Insert,
    })
}

fn upsert_key(table: &Table, req: &Request) -> Result<String, String> {
    let name = match &req.on {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(a)) if a.len() == 1 => a[0]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| "on must name a column".to_owned())?,
        _ => return Err("upsert needs on: one unique column".to_owned()),
    };
    match table.column(&name) {
        Some(c) if c.unique => Ok(name),
        _ => Err("upsert on must be a declared unique column".to_owned()),
    }
}

fn upsert(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let key = upsert_key(table, req)?;
    let cols = assignments(table, required_values(req)?)?;
    if !cols.iter().any(|c| c.0 == key) {
        return Err("upsert values must include the on column".to_owned());
    }
    let sets: Vec<String> = cols
        .iter()
        .filter(|c| c.0 != key)
        .map(|c| format!("{0}=excluded.{0}", quote(&c.0)))
        .collect();
    let conflict = if sets.is_empty() {
        "DO NOTHING".to_owned()
    } else {
        format!("DO UPDATE SET {}", sets.join(","))
    };
    Ok(Statement {
        sql: format!(
            "{} ON CONFLICT({}) {conflict}",
            insert_head(q, &cols),
            quote(&key)
        ),
        binds: cols.into_iter().map(|c| c.1).collect(),
        shape: Shape::Changed,
    })
}

fn update(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let cols = assignments(table, required_values(req)?)?;
    if cols.is_empty() {
        return Err("update needs at least one value".to_owned());
    }
    let sets: Vec<String> = cols.iter().map(|c| format!("{}=?", quote(&c.0))).collect();
    let mut binds: Vec<Bind> = cols.into_iter().map(|c| c.1).collect();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    Ok(Statement {
        sql: format!("UPDATE {} SET {}{clause}", quote(q.0), sets.join(",")),
        binds,
        shape: Shape::Changed,
    })
}

fn delete(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let mut binds = Vec::new();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    Ok(Statement {
        sql: format!("DELETE FROM {}{clause}", quote(q.0)),
        binds,
        shape: Shape::Changed,
    })
}

fn select(table: &Table, q: &Quoted, req: &Request, first: bool) -> Result<Statement, String> {
    let mut shape = vec![(ID.to_owned(), ColumnType::Int)];
    shape.extend(table.columns.iter().map(|c| (c.name.clone(), c.ty)));
    let list: Vec<String> = shape.iter().map(|c| quote(&c.0)).collect();
    let mut binds = Vec::new();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    let order = order_clause(table, &req.order)?;
    let limit = if first { 1 } else { row_limit(req.limit)? };
    let offset = req.offset.unwrap_or(0);
    if !(0..=MAX_OFFSET).contains(&offset) {
        return Err("offset is out of range".to_owned());
    }
    Ok(Statement {
        sql: format!(
            "SELECT {} FROM {}{clause}{order} LIMIT {limit} OFFSET {offset}",
            list.join(","),
            quote(q.0)
        ),
        binds,
        shape: Shape::Rows(shape),
    })
}

fn row_limit(limit: Option<i64>) -> Result<i64, String> {
    match limit {
        None => Ok(MAX_ROWS),
        Some(n) if (1..=MAX_ROWS).contains(&n) => Ok(n),
        Some(_) => Err(format!("limit must be 1 to {MAX_ROWS}")),
    }
}

fn count(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let mut binds = Vec::new();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    Ok(Statement {
        sql: format!("SELECT COUNT(*) FROM {}{clause}", quote(q.0)),
        binds,
        shape: Shape::Scalar(ColumnType::Int),
    })
}

fn numeric_column(table: &Table, req: &Request) -> Result<(String, ColumnType), String> {
    let name = req
        .col
        .as_deref()
        .ok_or_else(|| "this op needs col".to_owned())?;
    match table.column(name) {
        Some(c) if matches!(c.ty, ColumnType::Int | ColumnType::Real) => {
            Ok((name.to_owned(), c.ty))
        }
        _ => Err("col must be a declared int or real column".to_owned()),
    }
}

fn sum(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let (col, ty) = numeric_column(table, req)?;
    let mut binds = Vec::new();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    let zero = if ty == ColumnType::Real { "0.0" } else { "0" };
    Ok(Statement {
        sql: format!(
            "SELECT COALESCE(SUM({}),{zero}) FROM {}{clause}",
            quote(&col),
            quote(q.0)
        ),
        binds,
        shape: Shape::Scalar(ty),
    })
}

fn increment(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let (col, ty) = numeric_column(table, req)?;
    let by = match (&req.by, ty) {
        (None, ColumnType::Int) => Bind::Int(1),
        (Some(v), _) => to_bind(ty, v)?,
        (None, _) => return Err("increment needs by".to_owned()),
    };
    if matches!(by, Bind::Null) || matches!(by, Bind::Int(n) if n.abs() > MAX_INCREMENT) {
        return Err("by is out of range".to_owned());
    }
    let mut binds = vec![by];
    let clause = where_clause(table, &req.filters, &mut binds)?;
    let c = quote(&col);
    Ok(Statement {
        sql: format!("UPDATE {} SET {c}=COALESCE({c},0)+?{clause}", quote(q.0)),
        binds,
        shape: Shape::Changed,
    })
}

fn where_clause(
    table: &Table,
    filters: &[Condition],
    binds: &mut Vec<Bind>,
) -> Result<String, String> {
    if filters.len() > MAX_CONDITIONS {
        return Err("too many where conditions".to_owned());
    }
    let mut parts = Vec::new();
    for cond in filters {
        let ty = column_type(table, &cond.col)?;
        let col = quote(&cond.col);
        let part = match cond.op.as_str() {
            "eq" => format!("{col} = ?"),
            "ne" => format!("{col} IS NOT ?"),
            "gt" => format!("{col} > ?"),
            "gte" => format!("{col} >= ?"),
            "lt" => format!("{col} < ?"),
            "lte" => format!("{col} <= ?"),
            "like" if ty == ColumnType::Text => format!("{col} LIKE ? ESCAPE '\\'"),
            "in" => in_list(&col, ty, &cond.val, binds)?,
            _ => return Err("unknown where operator".to_owned()),
        };
        if cond.op != "in" {
            let bind = to_bind(ty, &cond.val)?;
            if bind == Bind::Null {
                return Err("where values cannot be null".to_owned());
            }
            binds.push(bind);
        }
        parts.push(part);
    }
    if parts.is_empty() {
        return Ok(String::new());
    }
    Ok(format!(" WHERE {}", parts.join(" AND ")))
}

fn in_list(
    col: &str,
    ty: ColumnType,
    val: &Value,
    binds: &mut Vec<Bind>,
) -> Result<String, String> {
    let items = val
        .as_array()
        .filter(|a| (1..=MAX_IN_VALUES).contains(&a.len()))
        .ok_or_else(|| format!("in needs a list of 1 to {MAX_IN_VALUES} values"))?;
    for item in items {
        let bind = to_bind(ty, item)?;
        if bind == Bind::Null {
            return Err("where values cannot be null".to_owned());
        }
        binds.push(bind);
    }
    Ok(format!("{col} IN ({})", vec!["?"; items.len()].join(",")))
}

fn order_clause(table: &Table, order: &[Order]) -> Result<String, String> {
    if order.len() > MAX_ORDER {
        return Err("too many order entries".to_owned());
    }
    let mut parts = Vec::new();
    for entry in order {
        column_type(table, &entry.col)?;
        let dir = match entry.dir.as_deref() {
            None | Some("asc") => "ASC",
            Some("desc") => "DESC",
            Some(_) => return Err("order dir must be asc or desc".to_owned()),
        };
        parts.push(format!("{} {dir}", quote(&entry.col)));
    }
    parts.push(format!("{} ASC", quote(ID)));
    Ok(format!(" ORDER BY {}", parts.join(",")))
}
