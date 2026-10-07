// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates schema/openapi.yaml's `"400"` response on every operation whose input
//! the server parses and refuses.
//!
//! A path id goes through `parse_uuid` and a typed query value through the
//! custom `Query` extractor, and both answer `400 {"error": ...}` for a value
//! that does not parse. An operation that takes either but lists no `"400"`
//! leaves a generated or third-party client with no documented error shape for
//! a malformed id.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde_yaml_ng::Value;

const METHODS: [&str; 5] = ["get", "post", "put", "patch", "delete"];

fn load_schema() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema/openapi.yaml");
    let text = fs::read_to_string(path).expect("read openapi.yaml");
    serde_yaml_ng::from_str(&text).expect("parse openapi.yaml")
}

fn resolve<'a>(doc: &'a Value, parameter: &'a Value) -> &'a Value {
    let Some(reference) = parameter.get("$ref").and_then(Value::as_str) else {
        return parameter;
    };
    let name = reference
        .strip_prefix("#/components/parameters/")
        .unwrap_or_else(|| panic!("unresolvable parameter $ref: {reference}"));
    doc["components"]["parameters"]
        .get(name)
        .unwrap_or_else(|| panic!("parameter {name} is undefined"))
}

/// Whether the server validates this parameter and refuses a bad value.
fn is_parsed(parameter: &Value) -> bool {
    let schema = &parameter["schema"];
    let format = schema.get("format").and_then(Value::as_str);
    let kind = schema.get("type").and_then(Value::as_str);
    match parameter["in"].as_str() {
        Some("path") => format == Some("uuid"),
        Some("query") => {
            matches!(kind, Some("integer" | "number" | "boolean"))
                || format == Some("uuid")
                || schema.get("enum").is_some()
        }
        _ => false,
    }
}

/// Every operation with a parsed parameter, and whether it lists a `"400"`.
fn parsed_operations(doc: &Value) -> Vec<(String, bool)> {
    let mut found = Vec::new();
    let paths = doc["paths"].as_mapping().expect("paths");
    for (_, item) in paths {
        let shared = item.get("parameters").and_then(Value::as_sequence);
        for method in METHODS {
            let Some(operation) = item.get(method) else {
                continue;
            };
            let own = operation.get("parameters").and_then(Value::as_sequence);
            let parsed = shared
                .into_iter()
                .chain(own)
                .flatten()
                .any(|p| is_parsed(resolve(doc, p)));
            if !parsed {
                continue;
            }
            let id = operation["operationId"].as_str().expect("operationId");
            let documented = operation["responses"].get("400").is_some();
            found.push((id.to_string(), documented));
        }
    }
    found
}

#[test]
fn every_operation_with_a_parsed_parameter_documents_a_400() {
    let missing: BTreeSet<_> = parsed_operations(&load_schema())
        .into_iter()
        .filter(|(_, documented)| !documented)
        .map(|(id, _)| id)
        .collect();
    assert!(
        missing.is_empty(),
        "these operations take a uuid path id or a typed query value, which the \
         server refuses with a 400 when it does not parse, and list no \"400\" \
         response: {missing:?}\n\
         Add `\"400\": $ref: \"#/components/responses/BadRequest\"` to each.",
    );
}

/// A scanner that finds nothing would make the gate above pass vacuously.
#[test]
fn the_scanner_finds_the_operations_it_gates() {
    let found = parsed_operations(&load_schema());
    assert!(
        found.len() >= 60,
        "suspiciously few operations: {}",
        found.len()
    );
    assert!(found.iter().any(|(id, _)| id == "listMessages"));
}
