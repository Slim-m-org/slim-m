// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The surfaces a connector may declare (add-on API 7): its own permission keys
//! and the extension points a member reaches through a run the host forwards to
//! the connector (`http::connector_runs`). Kinds whose runs the host starts on
//! its own, or whose input is someone else's text, stay WASM only.

use super::{ManifestConnector, ManifestError, ManifestExtensionPoint, malformed};

/// The extension-point kinds a connector serves: each is one member's run, answered once.
pub(super) const CONNECTOR_KINDS: [&str; 3] = ["command", "slash-command", "panel"];

/// For a connector, refuses an extension point it cannot serve, naming the kinds it can.
pub(super) fn check(
    connector: Option<&ManifestConnector>,
    points: &[ManifestExtensionPoint],
) -> Result<(), ManifestError> {
    if connector.is_none() {
        return Ok(());
    }
    match points
        .iter()
        .find(|p| !CONNECTOR_KINDS.contains(&p.kind.as_str()))
    {
        Some(point) => Err(malformed(&format!(
            "a connector may not declare a {} extension point (supported: {})",
            point.kind,
            CONNECTOR_KINDS.join(", ")
        ))),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::super::{ManifestError, parse_manifest};

    fn connector(points: Value) -> Value {
        json!({
            "schema": 1,
            "id": "pelican",
            "name": "Pelican",
            "version": "1.0.0",
            "summary": "game servers",
            "provider": "connector",
            "addon_api": 7,
            "connector": {"permissions": ["view_channel"]},
            "permissions": [{"key": "use", "name": "Use", "description": "see the servers"}],
            "extension_points": points
        })
    }

    fn parse(doc: &Value) -> Result<super::super::Manifest, String> {
        parse_manifest(doc.to_string().as_bytes()).map_err(|ManifestError::Malformed(why)| why)
    }

    const COMMAND: &str = r#"{"kind": "command", "name": "servers", "permission": "use"}"#;

    fn points(extra: &[&str]) -> Value {
        let all: Vec<Value> = std::iter::once(COMMAND)
            .chain(extra.iter().copied())
            .map(|p| serde_json::from_str(p).unwrap())
            .collect();
        Value::Array(all)
    }

    #[test]
    fn a_connector_declares_a_command_a_slash_command_and_a_panel() {
        let doc = connector(points(&[
            r#"{"kind": "slash-command", "name": "servers", "permission": "use", "command": "servers"}"#,
            r#"{"kind": "panel", "name": "Servers", "permission": "use", "command": "servers"}"#,
        ]));
        let manifest = parse(&doc).unwrap();
        let kinds: Vec<&str> = manifest
            .extension_points
            .iter()
            .map(|p| p.kind.as_str())
            .collect();
        assert_eq!(kinds, ["command", "slash-command", "panel"]);
        assert_eq!(manifest.permissions.len(), 1);
        assert!(manifest.connector.is_some());
    }

    #[test]
    fn a_connector_refuses_the_kinds_it_cannot_serve() {
        for point in [
            r#"{"kind": "app", "name": "Board", "permission": "use", "command": "servers"}"#,
            r#"{"kind": "code-block-runner", "name": "Run", "permission": "use", "command": "servers"}"#,
            r#"{"kind": "canvas-tile", "name": "Tile", "permission": "use", "command": "servers"}"#,
            r#"{"kind": "badge", "name": "Unknown"}"#,
        ] {
            let why = parse(&connector(points(&[point]))).unwrap_err();
            assert!(why.contains("may not declare a"), "{point}: {why}");
        }
    }

    #[test]
    fn a_connector_command_still_names_a_declared_permission() {
        let doc = connector(json!([{"kind": "command", "name": "servers", "permission": "nope"}]));
        assert!(parse(&doc).unwrap_err().contains("permission"));
    }
}
