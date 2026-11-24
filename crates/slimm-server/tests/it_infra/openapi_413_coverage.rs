// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates schema/openapi.yaml's `"413"` response on every operation that takes a
//! request body: each route caps its body, and a body over the cap answers 413
//! before it is parsed.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::support;
const METHODS: [&str; 5] = ["get", "post", "put", "patch", "delete"];

fn load_schema() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema/openapi.yaml");
    let text = fs::read_to_string(path).expect("read openapi.yaml");
    support::openapi::parse_schema_yaml(&text)
}

/// Every operation that takes a request body, and whether it lists a `"413"`.
fn body_operations(doc: &Value) -> Vec<(String, bool)> {
    let paths = doc["paths"].as_object().expect("paths");
    paths
        .values()
        .flat_map(|item| METHODS.iter().filter_map(|method| item.get(*method)))
        .filter(|operation| operation.get("requestBody").is_some())
        .map(|operation| {
            let id = operation["operationId"].as_str().expect("operationId");
            (id.to_string(), operation["responses"].get("413").is_some())
        })
        .collect()
}

#[test]
fn every_operation_with_a_request_body_documents_a_413() {
    let missing: BTreeSet<_> = body_operations(&load_schema())
        .into_iter()
        .filter(|(_, documented)| !documented)
        .map(|(id, _)| id)
        .collect();
    assert!(
        missing.is_empty(),
        "these operations take a request body, which the server refuses with a \
         413 when it is over the route's limit, and list no \"413\" response: \
         {missing:?}\n\
         Add `\"413\": $ref: \"#/components/responses/PayloadTooLarge\"` to each.",
    );
}

/// A scanner that finds nothing would make the gate above pass vacuously.
#[test]
fn the_scanner_finds_the_operations_it_gates() {
    let found = body_operations(&load_schema());
    assert!(
        found.len() >= 120,
        "suspiciously few operations: {}",
        found.len()
    );
    assert!(found.iter().any(|(id, _)| id == "sendMessage"));
}
