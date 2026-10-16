// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! schema/openapi.yaml read as what it is.
//!
//! An OpenAPI 3.1 schema object *is* a JSON Schema 2020-12 schema, so a real
//! response is checked against the document itself rather than against a
//! hand-written expectation that would immediately become a second, rotting
//! copy of it.
//!
//! Two passes, because one keyword cannot do both jobs. The validator
//! answers "does the server still send everything the schema promises, with
//! the promised types" - `required`, `type`, `enum`, `format`, `$ref` and
//! `allOf` all come free and correct. It cannot answer "does the server send
//! anything the schema never mentions" without `additionalProperties: false`
//! or `unevaluatedProperties: false`, and injecting either breaks
//! composition: `PinnedMessage` is `allOf: [Message, ...]`, so a closed
//! `Message` would reject the very fields the other branch adds. The second
//! pass is therefore a small walk that unions the property names the schema
//! documents at each position and reports the rest.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use jsonschema::Validator;
use serde_json::{Value, json};

pub struct Api {
    doc: Value,
    pub operations: BTreeMap<String, Operation>,
}

pub struct Operation {
    pub method: String,
    pub path: String,
    /// Status code -> media type -> that media type's schema, if it declares
    /// one. An empty media map is a response documented with no body at all.
    pub responses: BTreeMap<String, BTreeMap<String, Option<Value>>>,
}

impl Api {
    pub fn load(repo_root: &Path) -> Api {
        let path = repo_root.join("schema/openapi.yaml");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        let doc: Value = crate::support::openapi::parse_schema_yaml(&text);

        let mut operations = BTreeMap::new();
        let paths = doc["paths"]
            .as_object()
            .expect("schema/openapi.yaml has no `paths:` map");
        for (path, item) in paths {
            let item = item.as_object().expect("a path item is a map");
            for (method, operation) in item {
                let Some(id) = operation["operationId"].as_str() else {
                    continue;
                };
                let previous = operations.insert(
                    id.to_string(),
                    Operation {
                        method: method.to_uppercase(),
                        path: path.clone(),
                        responses: read_responses(&doc, &operation["responses"]),
                    },
                );
                assert!(previous.is_none(), "operationId {id} is used twice");
            }
        }
        assert!(
            !operations.is_empty(),
            "no operations found under `paths:`; the loader is broken, not the schema"
        );
        Api { doc, operations }
    }

    /// Compiles one response schema. `components` rides along at the root so
    /// every `#/components/schemas/...` pointer in the document resolves
    /// without a network or filesystem retriever.
    pub fn validator(&self, schema: &Value) -> Validator {
        let root = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": "#/$defs/target",
            "$defs": { "target": schema },
            "components": self.doc["components"],
        });
        jsonschema::options()
            .should_validate_formats(true)
            .build(&root)
            .expect("a response schema in schema/openapi.yaml does not compile")
    }

    /// Property names present in `instance` that the schema documents nowhere
    /// at that position, reported as instance paths.
    pub fn undocumented(&self, schema: &Value, instance: &Value) -> Vec<String> {
        let mut found = Vec::new();
        self.walk(schema, instance, "", &mut found);
        found
    }

    fn walk(&self, schema: &Value, instance: &Value, at: &str, found: &mut Vec<String>) {
        match instance {
            Value::Object(fields) => {
                let documented = self.properties_of(schema);
                // Nothing documented here at all means a free-form object, not
                // an object whose every field is a surprise.
                if documented.is_empty() {
                    return;
                }
                for (name, value) in fields {
                    let here = format!("{at}/{name}");
                    match documented.get(name) {
                        Some(subschemas) => {
                            for sub in subschemas {
                                self.walk(sub, value, &here, found);
                            }
                        }
                        None => found.push(here),
                    }
                }
            }
            Value::Array(items) => {
                let item_schemas = self.branches(schema, "items");
                for (index, value) in items.iter().enumerate() {
                    let here = format!("{at}/{index}");
                    for sub in &item_schemas {
                        self.walk(sub, value, &here, found);
                    }
                }
            }
            _ => {}
        }
    }

    /// Every property the schema documents at this position, unioned across
    /// `$ref` and every composition branch.
    fn properties_of<'a>(&'a self, schema: &'a Value) -> BTreeMap<String, Vec<&'a Value>> {
        let mut merged: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
        for node in self.resolve(schema) {
            if let Some(properties) = node["properties"].as_object() {
                for (name, subschema) in properties {
                    merged.entry(name.clone()).or_default().push(subschema);
                }
            }
        }
        merged
    }

    /// The subschemas reachable under `key`, again unioned across `$ref` and
    /// composition, so `items` on an `allOf` branch is not missed.
    fn branches<'a>(&'a self, schema: &'a Value, key: &str) -> Vec<&'a Value> {
        self.resolve(schema)
            .into_iter()
            .filter(|node| node.get(key).is_some())
            .map(|node| &node[key])
            .collect()
    }

    /// Flattens a schema into the nodes that constrain it directly: itself,
    /// whatever its `$ref` points at, and every `allOf`/`oneOf`/`anyOf`
    /// branch, transitively. A union is deliberately permissive for `oneOf`:
    /// this pass exists to catch fields nothing documents, and reporting a
    /// field that one branch does document would be a false alarm.
    fn resolve<'a>(&'a self, schema: &'a Value) -> Vec<&'a Value> {
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        self.flatten(schema, &mut out, &mut seen);
        out
    }

    fn flatten<'a>(
        &'a self,
        schema: &'a Value,
        out: &mut Vec<&'a Value>,
        seen: &mut BTreeSet<String>,
    ) {
        if !schema.is_object() {
            return;
        }
        if let Some(pointer) = schema["$ref"].as_str()
            && seen.insert(pointer.to_string())
            && let Some(target) = self.doc.pointer(pointer.trim_start_matches('#'))
        {
            self.flatten(target, out, seen);
        }
        out.push(schema);
        for keyword in ["allOf", "oneOf", "anyOf"] {
            if let Some(branches) = schema[keyword].as_array() {
                for branch in branches {
                    self.flatten(branch, out, seen);
                }
            }
        }
    }
}

/// Reads an operation's `responses:` map, following a `$ref` to
/// `#/components/responses/...` so a shared error response is not invisible.
fn read_responses(
    doc: &Value,
    responses: &Value,
) -> BTreeMap<String, BTreeMap<String, Option<Value>>> {
    let mut out = BTreeMap::new();
    let Some(map) = responses.as_object() else {
        return out;
    };
    for (status, response) in map {
        let resolved = match response["$ref"].as_str() {
            Some(pointer) => doc
                .pointer(pointer.trim_start_matches('#'))
                .unwrap_or_else(|| panic!("dangling response $ref {pointer}")),
            None => response,
        };
        let mut media = BTreeMap::new();
        if let Some(content) = resolved["content"].as_object() {
            for (media_type, body) in content {
                let schema = body.get("schema").cloned();
                media.insert(media_type.clone(), schema);
            }
        }
        out.insert(status.clone(), media);
    }
    out
}
