// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tests for [`super::manifest`], split into this path-based child module
//! purely to hold `manifest.rs` under the file-budget ceiling.

use super::*;
use crate::module_runtime::{MAX_FUEL, MAX_MEMORY_MB, MAX_WALL_MS};

pub(super) const GOOD_INDEX: &str = r#"{
    "schema": 1,
    "modules": [
        {"id": "code-exec", "name": "Code Blocks", "version": "0.1.0", "summary": "runs code"}
    ]
}"#;

pub(super) const GOOD_MANIFEST: &str = r#"{
    "schema": 1,
    "id": "code-exec",
    "name": "Code Blocks",
    "version": "0.1.0",
    "summary": "runs code",
    "author": "slim-m",
    "artifact": {
        "kind": "wasm",
        "path": "modules/code-exec/0.1.0/module.wasm",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
    "permissions": [
        {"key": "run", "name": "Execute code blocks", "description": "run a snippet"}
    ],
    "capabilities": ["command.register", "message.post"],
    "extension_points": [
        {"kind": "command", "name": "run", "description": "runs it", "permission": "run"}
    ]
}"#;

#[test]
fn parses_the_live_registry_shapes() {
    let index = parse_index(GOOD_INDEX.as_bytes()).unwrap();
    assert_eq!(index.len(), 1);
    assert_eq!(index[0].id, "code-exec");

    let manifest = parse_manifest(GOOD_MANIFEST.as_bytes()).unwrap();
    assert_eq!(manifest.id, "code-exec");
    assert_eq!(manifest.permissions.len(), 1);
    assert_eq!(manifest.permissions[0].key, "run");
    assert_eq!(manifest.artifact.sha256.len(), 64);
    assert_eq!(
        manifest.extension_points[0].permission.as_deref(),
        Some("run")
    );
}

/// Forward-compatibility invariant: a manifest carrying an extension-point
/// kind and a capability this server has never heard of still parses. It
/// keeps what it does not understand and ignores it, so a future module class
/// (a theme, a panel, a channel-surface, an event handler) is an additive
/// change that installs on today's server rather than one needing the server
/// bumped in lockstep. This is the invariant the "modules extend slim through
/// bounded contracts, they never patch it" model rests on; see decision 0022.
#[test]
fn accepts_an_unknown_extension_point_kind_and_capability() {
    let forward = GOOD_MANIFEST
        .replace(
            r#""capabilities": ["command.register", "message.post"]"#,
            r#""capabilities": ["command.register", "surface.render"]"#,
        )
        .replace(
            r#"{"kind": "command", "name": "run", "description": "runs it", "permission": "run"}"#,
            r#"{"kind": "command", "name": "run", "description": "runs it", "permission": "run"}, {"kind": "channel-surface", "name": "podcast", "description": "a kind from the future"}"#,
        );
    let manifest = parse_manifest(forward.as_bytes()).expect("a future kind parses");
    assert!(
        manifest.capabilities.iter().any(|c| c == "surface.render"),
        "an unknown capability is retained, not rejected"
    );
    assert!(
        manifest
            .extension_points
            .iter()
            .any(|e| e.kind == "channel-surface"),
        "an unknown extension-point kind is retained, not rejected"
    );
}

#[test]
fn rejects_a_command_extension_point_with_no_permission() {
    let bad = GOOD_MANIFEST.replace(r#", "permission": "run""#, "");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_command_extension_point_naming_an_undeclared_permission() {
    let bad = GOOD_MANIFEST.replace(r#""permission": "run""#, r#""permission": "ghost""#);
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

pub(super) const GOOD_MANIFEST_WITH_RUNNER: &str = r#"{
    "schema": 1,
    "id": "code-exec",
    "name": "Code Blocks",
    "version": "0.1.0",
    "summary": "runs code",
    "author": "slim-m",
    "artifact": {
        "kind": "wasm",
        "path": "modules/code-exec/0.1.0/module.wasm",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
    "permissions": [
        {"key": "run", "name": "Execute code blocks", "description": "run a snippet"}
    ],
    "capabilities": ["command.register", "message.post"],
    "extension_points": [
        {"kind": "command", "name": "run", "description": "runs it", "permission": "run"},
        {"kind": "code-block-runner", "name": "Run in chat", "permission": "run", "command": "run"}
    ]
}"#;

#[test]
fn parses_a_code_block_runner_extension_point() {
    let manifest = parse_manifest(GOOD_MANIFEST_WITH_RUNNER.as_bytes()).unwrap();
    let runner = manifest
        .extension_points
        .iter()
        .find(|e| e.kind == "code-block-runner")
        .unwrap();
    assert_eq!(runner.command.as_deref(), Some("run"));
    assert_eq!(runner.permission.as_deref(), Some("run"));
}

#[test]
fn rejects_a_code_block_runner_with_no_permission() {
    let bad = GOOD_MANIFEST_WITH_RUNNER.replace(r#", "permission": "run", "command": "run""#, "");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_code_block_runner_naming_an_undeclared_permission() {
    let bad = GOOD_MANIFEST_WITH_RUNNER.replacen(
        r#""permission": "run", "command": "run""#,
        r#""permission": "ghost", "command": "run""#,
        1,
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_code_block_runner_with_no_command() {
    let bad = GOOD_MANIFEST_WITH_RUNNER.replace(r#", "command": "run""#, "");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn parses_a_code_block_runner_language() {
    let with_language = GOOD_MANIFEST_WITH_RUNNER.replace(
        r#""permission": "run", "command": "run""#,
        r#""permission": "run", "command": "run", "language": "javascript""#,
    );
    let manifest = parse_manifest(with_language.as_bytes()).unwrap();
    let runner = manifest
        .extension_points
        .iter()
        .find(|e| e.kind == "code-block-runner")
        .unwrap();
    assert_eq!(runner.language.as_deref(), Some("javascript"));
}

#[test]
fn a_code_block_runner_with_no_language_is_a_wildcard() {
    let manifest = parse_manifest(GOOD_MANIFEST_WITH_RUNNER.as_bytes()).unwrap();
    let runner = manifest
        .extension_points
        .iter()
        .find(|e| e.kind == "code-block-runner")
        .unwrap();
    assert_eq!(runner.language, None);
}

#[test]
fn rejects_an_unsafe_extension_point_language() {
    let bad = GOOD_MANIFEST_WITH_RUNNER.replace(
        r#""permission": "run", "command": "run""#,
        r#""permission": "run", "command": "run", "language": "Java_Script!""#,
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_code_block_runner_naming_an_undeclared_command() {
    let bad = GOOD_MANIFEST_WITH_RUNNER.replacen(
        r#""command": "run""#,
        r#""command": "does-not-exist""#,
        1,
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

pub(super) const GOOD_MANIFEST_WITH_APP: &str = r#"{
    "schema": 1,
    "id": "game-of-life",
    "name": "Game of Life",
    "version": "0.1.0",
    "summary": "an in-chat game",
    "author": "slim-m",
    "artifact": {
        "kind": "wasm",
        "path": "modules/game-of-life/0.1.0/module.wasm",
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    },
    "runtime": {"backend": "wasm", "limits": {"memory_mb": 64, "wall_ms": 2000, "fuel": 500000000}},
    "permissions": [
        {"key": "play", "name": "Play the game", "description": "run it"}
    ],
    "capabilities": ["command.register"],
    "extension_points": [
        {"kind": "command", "name": "life", "description": "steps it", "permission": "play"},
        {"kind": "app", "name": "Game of Life", "description": "launch it in chat", "permission": "play", "command": "life"}
    ]
}"#;

#[test]
fn parses_an_app_extension_point() {
    let manifest = parse_manifest(GOOD_MANIFEST_WITH_APP.as_bytes()).unwrap();
    let app = manifest
        .extension_points
        .iter()
        .find(|e| e.kind == "app")
        .unwrap();
    assert_eq!(app.command.as_deref(), Some("life"));
    assert_eq!(app.permission.as_deref(), Some("play"));
}

#[test]
fn rejects_an_app_with_no_permission() {
    let bad = GOOD_MANIFEST_WITH_APP.replace(r#", "permission": "play", "command": "life""#, "");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_an_app_with_no_command() {
    let bad = GOOD_MANIFEST_WITH_APP.replace(r#", "command": "life""#, "");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_an_app_naming_an_undeclared_command() {
    let bad = GOOD_MANIFEST_WITH_APP.replacen(
        r#""command": "life""#,
        r#""command": "does-not-exist""#,
        1,
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_malformed_json() {
    assert!(matches!(
        parse_manifest(b"not json"),
        Err(ManifestError::Malformed(_))
    ));
    assert!(matches!(
        parse_index(b"{}"),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_an_unsafe_module_id() {
    let bad = GOOD_MANIFEST.replace("\"code-exec\"", "\"Code_Exec!\"");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_an_unsafe_permission_key() {
    let bad = GOOD_MANIFEST.replace("\"key\": \"run\"", "\"key\": \"Run Now\"");
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_short_sha256() {
    let bad = GOOD_MANIFEST.replace(
        "0000000000000000000000000000000000000000000000000000000000000000",
        "abc123",
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

/// A manifest's limits are its own ceiling, but the host has a ceiling too:
/// a manifest asking for more memory, time, or fuel than the host is willing
/// to pay for is refused at parse, before it can be installed at all.
#[test]
fn rejects_runtime_limits_above_the_host_maximum() {
    for (field, over) in [
        (
            "\"memory_mb\": 64",
            format!("\"memory_mb\": {}", MAX_MEMORY_MB + 1),
        ),
        (
            "\"wall_ms\": 2000",
            format!("\"wall_ms\": {}", MAX_WALL_MS + 1),
        ),
        ("\"fuel\": 500000000", format!("\"fuel\": {}", MAX_FUEL + 1)),
    ] {
        let bad = GOOD_MANIFEST.replace(field, &over);
        assert!(
            matches!(
                parse_manifest(bad.as_bytes()),
                Err(ManifestError::Malformed(_))
            ),
            "{over} should be refused"
        );
    }
    let at_max = GOOD_MANIFEST.replace(
        "\"memory_mb\": 64",
        &format!("\"memory_mb\": {MAX_MEMORY_MB}"),
    );
    assert!(parse_manifest(at_max.as_bytes()).is_ok());
}

#[test]
fn rejects_an_unsupported_schema_version() {
    let bad = GOOD_MANIFEST.replacen("\"schema\": 1,", "\"schema\": 99,", 1);
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn rejects_a_path_traversal_artifact_path() {
    let bad = GOOD_MANIFEST.replace(
        "\"modules/code-exec/0.1.0/module.wasm\"",
        "\"../../etc/passwd\"",
    );
    assert!(matches!(
        parse_manifest(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn slug_validator_accepts_only_lowercase_alnum_and_hyphen() {
    assert!(validate_slug("code-exec", 64).is_ok());
    assert!(validate_slug("a1-b2", 64).is_ok());
    assert!(validate_slug("", 64).is_err());
    assert!(validate_slug("Code-Exec", 64).is_err());
    assert!(validate_slug("code_exec", 64).is_err());
    assert!(validate_slug("code exec", 64).is_err());
    assert!(validate_slug(&"a".repeat(65), 64).is_err());
}
