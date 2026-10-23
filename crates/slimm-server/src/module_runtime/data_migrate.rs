// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turns the difference between a module's stored data schema and the one its
//! new manifest declares into DDL. Only additive change is allowed in the first
//! version: a removed table or column, or a retyped column, is refused.

use super::data_schema::{Column, DataSchema, Table};

/// The DDL that moves `old` (None for a file with no schema yet) to `new`, or why it cannot.
pub fn plan(old: Option<&DataSchema>, new: &DataSchema) -> Result<Vec<String>, String> {
    if let Some(old) = old {
        refuse_destructive(old, new)?;
    }
    let mut ddl = Vec::new();
    for table in &new.tables {
        match old.and_then(|o| o.table(&table.name)) {
            None => create_table(table, &mut ddl),
            Some(before) => alter_table(before, table, &mut ddl),
        }
    }
    Ok(ddl)
}

/// Columns of tables that already exist which `new` makes unique and `old` did not: a unique
/// index over rows that already repeat a value would fail halfway through an install.
pub fn newly_unique(old: &DataSchema, new: &DataSchema) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for table in &new.tables {
        let Some(before) = old.table(&table.name) else {
            continue;
        };
        for column in &table.columns {
            if column.unique && before.column(&column.name).is_some_and(|c| !c.unique) {
                out.push((table.name.clone(), column.name.clone()));
            }
        }
    }
    out
}

fn refuse_destructive(old: &DataSchema, new: &DataSchema) -> Result<(), String> {
    for before in &old.tables {
        let Some(after) = new.table(&before.name) else {
            return Err(format!(
                "table {} was removed; a data schema may only grow",
                before.name
            ));
        };
        for column in &before.columns {
            match after.column(&column.name) {
                None => {
                    return Err(format!(
                        "column {}.{} was removed; a data schema may only grow",
                        before.name, column.name
                    ));
                }
                Some(c) if c.ty != column.ty => {
                    return Err(format!(
                        "column {}.{} changed type; a data schema may only grow",
                        before.name, column.name
                    ));
                }
                Some(_) => {}
            }
        }
    }
    Ok(())
}

fn quote(identifier: &str) -> String {
    format!("\"{identifier}\"")
}

fn column_def(column: &Column) -> String {
    format!("{} {}", quote(&column.name), column.ty.sql())
}

fn index_name(kind: &str, table: &str, column: &str) -> String {
    format!("{kind}{}_{table}_{column}", table.len())
}

fn create_index(table: &str, column: &str, unique: bool) -> String {
    let (kind, word) = if unique {
        ("ux", "UNIQUE ")
    } else {
        ("ix", "")
    };
    format!(
        "CREATE {word}INDEX IF NOT EXISTS {} ON {} ({})",
        quote(&index_name(kind, table, column)),
        quote(table),
        quote(column)
    )
}

fn drop_index(kind: &str, table: &str, column: &str) -> String {
    format!(
        "DROP INDEX IF EXISTS {}",
        quote(&index_name(kind, table, column))
    )
}

fn index_statements(table: &str, column: &Column, ddl: &mut Vec<String>) {
    if column.unique {
        ddl.push(create_index(table, &column.name, true));
    }
    if column.index {
        ddl.push(create_index(table, &column.name, false));
    }
}

fn create_table(table: &Table, ddl: &mut Vec<String>) {
    let mut defs = vec!["\"_id\" INTEGER PRIMARY KEY AUTOINCREMENT".to_owned()];
    defs.extend(table.columns.iter().map(column_def));
    ddl.push(format!(
        "CREATE TABLE IF NOT EXISTS {} ({})",
        quote(&table.name),
        defs.join(", ")
    ));
    for column in &table.columns {
        index_statements(&table.name, column, ddl);
    }
}

fn alter_table(before: &Table, after: &Table, ddl: &mut Vec<String>) {
    for column in &after.columns {
        match before.column(&column.name) {
            None => {
                ddl.push(format!(
                    "ALTER TABLE {} ADD COLUMN {}",
                    quote(&after.name),
                    column_def(column)
                ));
                index_statements(&after.name, column, ddl);
            }
            Some(was) => {
                flag_change(&after.name, was.unique, column.unique, "ux", column, ddl);
                flag_change(&after.name, was.index, column.index, "ix", column, ddl);
            }
        }
    }
}

fn flag_change(
    table: &str,
    was: bool,
    now: bool,
    kind: &str,
    column: &Column,
    ddl: &mut Vec<String>,
) {
    if now && !was {
        ddl.push(create_index(table, &column.name, kind == "ux"));
    } else if was && !now {
        ddl.push(drop_index(kind, table, &column.name));
    }
}

#[cfg(test)]
mod tests {
    use super::super::data_schema::validate;
    use super::*;
    use serde_json::json;

    fn schema(cols: serde_json::Value) -> DataSchema {
        validate(&json!({ "tables": [{ "name": "t", "columns": cols }] })).unwrap()
    }

    #[test]
    fn a_new_schema_creates_tables_and_indexes() {
        let ddl = plan(
            None,
            &schema(json!([{ "name": "a", "type": "int", "unique": true, "index": true }])),
        )
        .unwrap();
        assert_eq!(ddl.len(), 3);
        assert!(ddl[0].starts_with("CREATE TABLE"));
    }

    #[test]
    fn growing_adds_columns_and_removing_or_retyping_is_refused() {
        let old = schema(json!([{ "name": "a", "type": "int" }]));
        let grown =
            schema(json!([{ "name": "a", "type": "int" }, { "name": "b", "type": "text" }]));
        let ddl = plan(Some(&old), &grown).unwrap();
        assert_eq!(ddl.len(), 1);
        assert!(ddl[0].contains("ADD COLUMN"));
        assert!(plan(Some(&grown), &old).is_err());
        let retyped = schema(json!([{ "name": "a", "type": "text" }]));
        assert!(plan(Some(&old), &retyped).is_err());
        let gone = validate(
            &json!({ "tables": [{ "name": "u", "columns": [{ "name": "a", "type": "int" }] }] }),
        )
        .unwrap();
        assert!(plan(Some(&old), &gone).is_err());
    }

    #[test]
    fn an_unchanged_schema_plans_nothing() {
        let s = schema(json!([{ "name": "a", "type": "int", "index": true }]));
        assert!(plan(Some(&s), &s).unwrap().is_empty());
    }

    #[test]
    fn index_names_cannot_collide_across_tables() {
        assert_ne!(index_name("ix", "a_b", "c"), index_name("ix", "a", "b_c"));
    }
}
