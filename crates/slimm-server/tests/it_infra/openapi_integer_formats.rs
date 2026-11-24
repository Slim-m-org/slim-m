// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates every `type: integer` in schema/openapi.yaml on a `format` or a
//! `maximum`: a generator reads a bare integer as 32 bits, which an epoch
//! millisecond or a byte count past 2 GiB overflows.

use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::support;

fn load_schema() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema/openapi.yaml");
    let text = fs::read_to_string(path).expect("read openapi.yaml");
    support::openapi::parse_schema_yaml(&text)
}

fn is_integer(node: &serde_json::Map<String, Value>) -> bool {
    match node.get("type") {
        Some(Value::String(kind)) => kind == "integer",
        Some(Value::Array(kinds)) => kinds.iter().any(|kind| kind == "integer"),
        _ => false,
    }
}

/// Every integer schema as (JSON pointer, whether it states a format or a maximum).
fn integers(node: &Value, pointer: &str, found: &mut Vec<(String, bool)>) {
    match node {
        Value::Object(map) => {
            if is_integer(map) {
                let bounded = map.contains_key("format") || map.contains_key("maximum");
                found.push((pointer.to_owned(), bounded));
            }
            for (key, child) in map {
                let escaped = key.replace('~', "~0").replace('/', "~1");
                integers(child, &format!("{pointer}/{escaped}"), found);
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                integers(child, &format!("{pointer}/{index}"), found);
            }
        }
        _ => {}
    }
}

fn all_integers() -> Vec<(String, bool)> {
    let mut found = Vec::new();
    integers(&load_schema(), "", &mut found);
    found
}

#[test]
fn every_integer_states_its_width() {
    let bare: Vec<_> = all_integers()
        .into_iter()
        .filter(|(_, bounded)| !bounded)
        .map(|(pointer, _)| pointer)
        .collect();
    assert!(
        bare.is_empty(),
        "these integers have neither a `format` nor a `maximum`, so a generated \
         client may read them as 32 bits: {bare:#?}\n\
         Add `format: int64` for a timestamp, byte count or other i64/u64 field, \
         or `format: int32` for a small one.",
    );
}

/// A scanner that finds nothing would make the gate above pass vacuously.
#[test]
fn the_scanner_finds_the_integers_it_gates() {
    let found = all_integers();
    assert!(
        found.len() >= 400,
        "suspiciously few integers: {}",
        found.len()
    );
    assert!(
        found
            .iter()
            .any(|(pointer, _)| pointer == "/components/schemas/AdminAlert/properties/raised_at")
    );
}
