// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The data a module declares in its manifest (decision 0091, `data`): tables,
//! typed columns and the file cap. Everything the host later builds SQL from
//! is validated here, so an identifier that passed [`validate`] is safe to
//! quote into a statement and nothing else ever is.

use serde::{Deserialize, Serialize};

/// Most tables one module may declare.
pub const MAX_TABLES: usize = 8;
/// Most columns one table may declare.
pub const MAX_COLUMNS: usize = 16;
/// Largest file cap a module may ask for, in megabytes.
pub const MAX_MB_LIMIT: u32 = 64;
/// The file cap when the manifest names none.
pub const DEFAULT_MAX_MB: u32 = 8;
/// Longest table or column name, in bytes.
pub const MAX_IDENT_BYTES: usize = 32;

/// A column's storage type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
/// Written as `int`, `real`, `text` or `bool` in the manifest.
#[serde(rename_all = "lowercase")]
pub enum ColumnType {
    Int,
    Real,
    Text,
    Bool,
}

impl ColumnType {
    pub(super) fn sql(self) -> &'static str {
        match self {
            ColumnType::Int | ColumnType::Bool => "INTEGER",
            ColumnType::Real => "REAL",
            ColumnType::Text => "TEXT",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// One typed column; `unique` and `index` add an index of that kind.
#[serde(deny_unknown_fields)]
pub struct Column {
    pub name: String,
    #[serde(rename = "type")]
    pub ty: ColumnType,
    #[serde(default)]
    pub unique: bool,
    #[serde(default)]
    pub index: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// A table; the host adds an integer primary key `_id`.
#[serde(deny_unknown_fields)]
pub struct Table {
    pub name: String,
    pub columns: Vec<Column>,
}

impl Table {
    pub fn column(&self, name: &str) -> Option<&Column> {
        self.columns.iter().find(|c| c.name == name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Everything a module declares under `data`.
#[serde(deny_unknown_fields)]
pub struct DataSchema {
    #[serde(default = "default_max_mb")]
    pub max_mb: u32,
    pub tables: Vec<Table>,
}

fn default_max_mb() -> u32 {
    DEFAULT_MAX_MB
}

impl DataSchema {
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables.iter().find(|t| t.name == name)
    }
}

/// Parses and checks a manifest's `data` value against every limit in decision 0091.
pub fn validate(value: &serde_json::Value) -> Result<DataSchema, String> {
    let schema: DataSchema =
        serde_json::from_value(value.clone()).map_err(|e| format!("invalid data schema: {e}"))?;
    if schema.max_mb == 0 || schema.max_mb > MAX_MB_LIMIT {
        return Err(format!("data.max_mb must be 1 to {MAX_MB_LIMIT}"));
    }
    if schema.tables.is_empty() || schema.tables.len() > MAX_TABLES {
        return Err(format!("data must declare 1 to {MAX_TABLES} tables"));
    }
    for (i, table) in schema.tables.iter().enumerate() {
        check_identifier(&table.name, "table")?;
        if schema.tables[..i].iter().any(|t| t.name == table.name) {
            return Err(format!("table {} is declared twice", table.name));
        }
        check_columns(table)?;
    }
    Ok(schema)
}

fn check_columns(table: &Table) -> Result<(), String> {
    if table.columns.is_empty() || table.columns.len() > MAX_COLUMNS {
        return Err(format!(
            "table {} must declare 1 to {MAX_COLUMNS} columns",
            table.name
        ));
    }
    for (i, column) in table.columns.iter().enumerate() {
        check_identifier(&column.name, "column")?;
        if table.columns[..i].iter().any(|c| c.name == column.name) {
            return Err(format!(
                "column {} is declared twice in {}",
                column.name, table.name
            ));
        }
    }
    Ok(())
}

fn check_identifier(name: &str, what: &str) -> Result<(), String> {
    let bytes = name.as_bytes();
    let well_formed = !bytes.is_empty()
        && bytes.len() <= MAX_IDENT_BYTES
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_');
    if !well_formed {
        return Err(format!(
            "{what} name {name:?} must be 1 to {MAX_IDENT_BYTES} lowercase letters, digits or underscores, starting with a letter"
        ));
    }
    if name.starts_with("sqlite") || KEYWORDS.contains(&name) {
        return Err(format!("{what} name {name:?} is reserved"));
    }
    Ok(())
}

/// SQLite's keywords, lowercased; refused even though identifiers are always quoted.
const KEYWORDS: &[&str] = &[
    "abort",
    "action",
    "add",
    "after",
    "all",
    "alter",
    "always",
    "analyze",
    "and",
    "as",
    "asc",
    "attach",
    "autoincrement",
    "before",
    "begin",
    "between",
    "by",
    "cascade",
    "case",
    "cast",
    "check",
    "collate",
    "column",
    "commit",
    "conflict",
    "constraint",
    "create",
    "cross",
    "current",
    "current_date",
    "current_time",
    "current_timestamp",
    "database",
    "default",
    "deferrable",
    "deferred",
    "delete",
    "desc",
    "detach",
    "distinct",
    "do",
    "drop",
    "each",
    "else",
    "end",
    "escape",
    "except",
    "exclude",
    "exclusive",
    "exists",
    "explain",
    "fail",
    "filter",
    "first",
    "following",
    "for",
    "foreign",
    "from",
    "full",
    "generated",
    "glob",
    "group",
    "groups",
    "having",
    "if",
    "ignore",
    "immediate",
    "in",
    "index",
    "indexed",
    "initially",
    "inner",
    "insert",
    "instead",
    "intersect",
    "into",
    "is",
    "isnull",
    "join",
    "key",
    "last",
    "left",
    "like",
    "limit",
    "match",
    "materialized",
    "natural",
    "no",
    "not",
    "nothing",
    "notnull",
    "null",
    "nulls",
    "of",
    "offset",
    "on",
    "or",
    "order",
    "others",
    "outer",
    "over",
    "partition",
    "plan",
    "pragma",
    "preceding",
    "primary",
    "query",
    "raise",
    "range",
    "recursive",
    "references",
    "regexp",
    "reindex",
    "release",
    "rename",
    "replace",
    "restrict",
    "returning",
    "right",
    "rollback",
    "row",
    "rows",
    "savepoint",
    "select",
    "set",
    "table",
    "temp",
    "temporary",
    "then",
    "ties",
    "to",
    "transaction",
    "trigger",
    "unbounded",
    "union",
    "unique",
    "update",
    "using",
    "vacuum",
    "values",
    "view",
    "virtual",
    "when",
    "where",
    "window",
    "with",
    "without",
    "rowid",
    "oid",
];

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn one(name: &str, col: &str) -> serde_json::Value {
        json!({ "tables": [{ "name": name, "columns": [{ "name": col, "type": "int" }] }] })
    }

    #[test]
    fn a_valid_schema_parses_with_the_default_cap() {
        let schema = validate(&json!({ "tables": [{ "name": "xp", "columns": [
            { "name": "user_id", "type": "text", "unique": true },
            { "name": "points", "type": "int", "index": true }] }] }))
        .unwrap();
        assert_eq!(schema.max_mb, DEFAULT_MAX_MB);
        assert!(
            schema
                .table("xp")
                .unwrap()
                .column("user_id")
                .unwrap()
                .unique
        );
    }

    #[test]
    fn identifiers_must_be_plain_lowercase() {
        for bad in [
            "",
            "Xp",
            "1xp",
            "_xp",
            "x-p",
            "x p",
            "x\"p",
            "x;drop",
            "xp'",
            "é",
            "sqlite_x",
            "select",
            "table",
            &"a".repeat(33),
        ] {
            assert!(validate(&one(bad, "c")).is_err(), "table {bad:?}");
            assert!(validate(&one("t", bad)).is_err(), "column {bad:?}");
        }
        assert!(validate(&one("t_1", "c_2")).is_ok());
    }

    #[test]
    fn limits_are_enforced() {
        let tables: Vec<_> = (0..9)
            .map(
                |i| json!({ "name": format!("t{i}"), "columns": [{ "name": "c", "type": "int" }] }),
            )
            .collect();
        assert!(validate(&json!({ "tables": tables })).is_err());
        let cols: Vec<_> = (0..17)
            .map(|i| json!({ "name": format!("c{i}"), "type": "int" }))
            .collect();
        assert!(validate(&json!({ "tables": [{ "name": "t", "columns": cols }] })).is_err());
        for mb in [0, 65] {
            let mut v = one("t", "c");
            v["max_mb"] = json!(mb);
            assert!(validate(&v).is_err(), "{mb}");
        }
        let mut v = one("t", "c");
        v["max_mb"] = json!(64);
        assert_eq!(validate(&v).unwrap().max_mb, 64);
    }

    #[test]
    fn duplicates_unknown_types_and_fields_are_refused() {
        let dup = json!({ "tables": [
            { "name": "t", "columns": [{ "name": "c", "type": "int" }] },
            { "name": "t", "columns": [{ "name": "c", "type": "int" }] }] });
        assert!(validate(&dup).is_err());
        let dup_col = json!({ "tables": [{ "name": "t", "columns": [
            { "name": "c", "type": "int" }, { "name": "c", "type": "text" }] }] });
        assert!(validate(&dup_col).is_err());
        let bad_ty =
            json!({ "tables": [{ "name": "t", "columns": [{ "name": "c", "type": "blob" }] }] });
        assert!(validate(&bad_ty).is_err());
        let extra = json!({ "tables": [{ "name": "t", "extra": 1, "columns": [{ "name": "c", "type": "int" }] }] });
        assert!(validate(&extra).is_err());
        assert!(validate(&json!({ "tables": [] })).is_err());
        assert!(validate(&json!("x")).is_err());
    }
}
