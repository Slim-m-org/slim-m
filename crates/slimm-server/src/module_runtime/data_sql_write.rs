// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The write ops of `data.store` (`insert`, `upsert`, `update`), split from
//! [`super::data_sql`] so each stays small. Same rules: identifiers only from
//! the declared schema, every value a bound parameter.

use serde_json::{Map, Value};

use super::data_schema::{ColumnType, Table};
use super::data_sql::{
    Bind, ID, Quoted, Request, Shape, Statement, amount_out_of_range, column_type, quote, to_bind,
    where_clause,
};

/// Most rows one multi-row `insert` may carry.
pub const MAX_INSERT_ROWS: usize = 50;

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

/// The `add` map as column names and bound amounts; numeric columns only.
fn additions(
    table: &Table,
    add: Option<&Map<String, Value>>,
) -> Result<Vec<(String, Bind)>, String> {
    let mut out = Vec::new();
    for (name, value) in add.into_iter().flatten() {
        let ty = match table.column(name) {
            Some(c) if matches!(c.ty, ColumnType::Int | ColumnType::Real) => c.ty,
            _ => return Err("add must name declared int or real columns".to_owned()),
        };
        if value.is_null() {
            return Err("add amounts cannot be null".to_owned());
        }
        let bind = to_bind(ty, value)?;
        if amount_out_of_range(&bind) {
            return Err("add amount is out of range".to_owned());
        }
        out.push((name.clone(), bind));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

fn reject_overlap(cols: &[(String, Bind)], adds: &[(String, Bind)]) -> Result<(), String> {
    if adds.iter().any(|a| cols.iter().any(|c| c.0 == a.0)) {
        return Err("a column cannot be in both values and add".to_owned());
    }
    Ok(())
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

fn all_columns(table: &Table) -> Vec<(String, ColumnType)> {
    let mut shape = vec![(ID.to_owned(), ColumnType::Int)];
    shape.extend(table.columns.iter().map(|c| (c.name.clone(), c.ty)));
    shape
}

pub(super) fn insert(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    if let Some(rows) = &req.rows {
        if req.values.is_some() {
            return Err("values and rows cannot be combined".to_owned());
        }
        return insert_rows(table, q, rows);
    }
    let cols = assignments(table, required_values(req)?)?;
    Ok(Statement {
        sql: insert_head(q, &cols),
        binds: cols.into_iter().map(|c| c.1).collect(),
        shape: Shape::Insert,
    })
}

fn insert_rows(
    table: &Table,
    q: &Quoted,
    rows: &[Map<String, Value>],
) -> Result<Statement, String> {
    if rows.is_empty() || rows.len() > MAX_INSERT_ROWS {
        return Err(format!("rows needs 1 to {MAX_INSERT_ROWS} rows"));
    }
    let mut built = Vec::new();
    for row in rows {
        built.push(assignments(table, row)?);
    }
    let names: Vec<&str> = built[0].iter().map(|c| c.0.as_str()).collect();
    if names.is_empty() {
        return Err("each row needs at least one value".to_owned());
    }
    if built
        .iter()
        .any(|row| row.iter().map(|c| c.0.as_str()).ne(names.iter().copied()))
    {
        return Err("every row must set the same columns".to_owned());
    }
    let list: Vec<String> = names.iter().map(|n| quote(n)).collect();
    let tuple = format!("({})", vec!["?"; names.len()].join(","));
    let tuples = vec![tuple; built.len()].join(",");
    let sql = format!(
        "INSERT INTO {} ({}) VALUES {tuples} RETURNING {}",
        quote(q.0),
        list.join(","),
        quote(ID)
    );
    Ok(Statement {
        sql,
        binds: built.into_iter().flatten().map(|c| c.1).collect(),
        shape: Shape::Returning(vec![(ID.to_owned(), ColumnType::Int)]),
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

pub(super) fn upsert(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let key = upsert_key(table, req)?;
    let mut cols = assignments(table, required_values(req)?)?;
    if !cols.iter().any(|c| c.0 == key) {
        return Err("upsert values must include the on column".to_owned());
    }
    let adds = additions(table, req.add.as_ref())?;
    reject_overlap(&cols, &adds)?;
    if adds.iter().any(|a| a.0 == key) {
        return Err("add cannot name the on column".to_owned());
    }
    let mut sets: Vec<String> = cols
        .iter()
        .filter(|c| c.0 != key)
        .map(|c| format!("{0}=excluded.{0}", quote(&c.0)))
        .collect();
    let t = quote(q.0);
    sets.extend(adds.iter().map(|a| {
        let c = quote(&a.0);
        format!("{c}=COALESCE({t}.{c},0)+excluded.{c}")
    }));
    let returning = !adds.is_empty();
    cols.extend(adds);
    let conflict = if sets.is_empty() {
        "DO NOTHING".to_owned()
    } else {
        format!("DO UPDATE SET {}", sets.join(","))
    };
    let mut sql = format!(
        "{} ON CONFLICT({}) {conflict}",
        insert_head(q, &cols),
        quote(&key)
    );
    let mut shape = Shape::Changed;
    if returning {
        let columns = all_columns(table);
        let list: Vec<String> = columns.iter().map(|c| quote(&c.0)).collect();
        sql.push_str(&format!(" RETURNING {}", list.join(",")));
        shape = Shape::Returning(columns);
    }
    Ok(Statement {
        sql,
        binds: cols.into_iter().map(|c| c.1).collect(),
        shape,
    })
}

pub(super) fn update(table: &Table, q: &Quoted, req: &Request) -> Result<Statement, String> {
    let adds = additions(table, req.add.as_ref())?;
    let cols = match (&req.values, adds.is_empty()) {
        (None, false) => Vec::new(),
        _ => assignments(table, required_values(req)?)?,
    };
    if cols.is_empty() && adds.is_empty() {
        return Err("update needs at least one value".to_owned());
    }
    reject_overlap(&cols, &adds)?;
    let mut sets: Vec<String> = cols.iter().map(|c| format!("{}=?", quote(&c.0))).collect();
    sets.extend(adds.iter().map(|a| {
        let c = quote(&a.0);
        format!("{c}=COALESCE({c},0)+?")
    }));
    let mut binds: Vec<Bind> = cols.into_iter().chain(adds).map(|c| c.1).collect();
    let clause = where_clause(table, &req.filters, &mut binds)?;
    Ok(Statement {
        sql: format!("UPDATE {} SET {}{clause}", quote(q.0), sets.join(",")),
        binds,
        shape: Shape::Changed,
    })
}
