// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a connector manifest may and may not declare.

use serde_json::{Value, json};

use super::super::{ManifestError, parse_manifest};
use crate::permissions::Permissions;

fn connector() -> Value {
    json!({
        "schema": 1,
        "id": "jellyfin",
        "name": "Jellyfin",
        "version": "0.1.0",
        "summary": "posts what is playing",
        "provider": "connector",
        "addon_api": 7,
        "connector": {"permissions": ["view_channel", "send_messages"]},
        "settings": [{"key": "api_key", "type": "secret", "label": "API key"}]
    })
}

fn parse(doc: &Value) -> Result<super::super::Manifest, String> {
    parse_manifest(doc.to_string().as_bytes()).map_err(|ManifestError::Malformed(why)| why)
}

#[test]
fn a_connector_parses_with_its_ask_and_no_artifact() {
    let manifest = parse(&connector()).unwrap();
    let asked = manifest.connector.unwrap().permissions;
    assert_eq!(
        asked,
        Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES)
    );
    assert_eq!(manifest.artifact.kind, "connector");
    assert_eq!(manifest.runtime.backend, "connector");
    assert_eq!(manifest.platform.settings_schema.len(), 1);
}

#[test]
fn a_connector_needs_level_7() {
    let mut doc = connector();
    doc["addon_api"] = json!(6);
    assert!(parse(&doc).unwrap_err().contains("\"addon_api\": 7"));
}

#[test]
fn a_connector_declares_none_of_a_wasm_module_s_sandbox() {
    for (field, value) in [
        (
            "artifact",
            json!({"kind": "wasm", "path": "m.wasm", "sha256": "0".repeat(64)}),
        ),
        ("runtime", json!({"backend": "wasm"})),
        ("capabilities", json!(["kv.store"])),
        ("schedules", json!([{"command": "x", "every_minutes": 5}])),
        ("subscriptions", json!([{"event": "message.created"}])),
        (
            "extension_points",
            json!([{"kind": "command", "name": "x", "permission": "x"}]),
        ),
        (
            "permissions",
            json!([{"key": "x", "name": "X", "description": "x"}]),
        ),
    ] {
        let mut doc = connector();
        doc[field] = value;
        let why = parse(&doc).unwrap_err();
        assert!(
            why.contains(&format!("may not declare {field}")),
            "{field}: {why}"
        );
    }
}

#[test]
fn the_ask_names_real_permissions_once() {
    for (names, wanted) in [
        (json!(["VIEW_CHANNEL"]), "lowercase"),
        (json!(["fly"]), "unknown permission"),
        (json!(["view_channel", "view_channel"]), "repeats"),
    ] {
        let mut doc = connector();
        doc["connector"]["permissions"] = names;
        let why = parse(&doc).unwrap_err();
        assert!(why.contains(wanted), "{why}");
    }
    let mut doc = connector();
    doc["connector"]["scopes"] = json!([]);
    assert!(
        parse(&doc).is_err(),
        "an unknown connector field is refused"
    );
}

#[test]
fn provider_and_connector_must_agree() {
    let mut doc = connector();
    doc.as_object_mut().unwrap().remove("connector");
    assert!(parse(&doc).unwrap_err().contains("connector.permissions"));
    let mut doc = connector();
    doc["provider"] = json!("docker");
    assert!(parse(&doc).unwrap_err().contains("not supported"));
    let mut doc = connector();
    doc.as_object_mut().unwrap().remove("provider");
    assert!(parse(&doc).unwrap_err().contains("only allowed"));
}

#[test]
fn a_wasm_module_still_needs_its_artifact() {
    let mut doc = connector();
    let obj = doc.as_object_mut().unwrap();
    obj.remove("provider");
    obj.remove("connector");
    assert!(parse(&doc).unwrap_err().contains("artifact and runtime"));
}

#[test]
fn the_ask_is_part_of_what_was_reviewed() {
    let narrow = parse(&connector()).unwrap().review_digest();
    let mut doc = connector();
    doc["connector"]["permissions"] = json!(["view_channel", "send_messages", "manage_roles"]);
    assert_ne!(parse(&doc).unwrap().review_digest(), narrow);
}
