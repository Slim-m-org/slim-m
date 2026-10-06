// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tests for the extension-point name rules and the hidden-character refusal,
//! split from `tests.rs` to keep both files under the file-budget ceiling.

use super::tests::{GOOD_INDEX, GOOD_MANIFEST};
use super::*;

const RUN_POINT: &str =
    r#"{"kind": "command", "name": "run", "description": "runs it", "permission": "run"}"#;

fn refusal(manifest: &str) -> String {
    match parse_manifest(manifest.as_bytes()) {
        Err(ManifestError::Malformed(reason)) => reason,
        Ok(_) => panic!("manifest was accepted"),
    }
}

fn with_point(point: &str) -> String {
    GOOD_MANIFEST.replace(RUN_POINT, &format!("{RUN_POINT}, {point}"))
}

#[test]
fn rejects_two_commands_with_the_same_name() {
    let stricter = r#"{"kind": "command", "name": "run", "permission": "run"}"#;
    let reason = refusal(&with_point(stricter));
    assert!(reason.contains("extension_points[].name"), "{reason}");
    assert!(reason.contains("run"), "{reason}");
}

#[test]
fn command_names_collide_regardless_of_case() {
    let shouty = r#"{"kind": "command", "name": "RUN", "permission": "run"}"#;
    assert!(refusal(&with_point(shouty)).contains("RUN"));
}

#[test]
fn rejects_two_slash_commands_with_the_same_keyword() {
    let one = r#"{"kind": "slash-command", "name": "roll", "permission": "run", "command": "run"}"#;
    let two = r#"{"kind": "slash-command", "name": "Roll", "permission": "run", "command": "run"}"#;
    let manifest = with_point(&format!("{one}, {two}"));
    assert!(refusal(&manifest).contains("Roll"));
}

#[test]
fn the_same_name_under_different_kinds_is_not_a_collision() {
    let slash =
        r#"{"kind": "slash-command", "name": "run", "permission": "run", "command": "run"}"#;
    assert!(parse_manifest(with_point(slash).as_bytes()).is_ok());
}

#[test]
fn code_block_runners_may_share_a_label_across_languages() {
    let py = r#"{"kind": "code-block-runner", "name": "Run", "permission": "run", "command": "run", "language": "py"}"#;
    let js = py.replace("py", "js");
    assert!(parse_manifest(with_point(&format!("{py}, {js}")).as_bytes()).is_ok());
}

#[test]
fn rejects_a_command_name_that_cannot_be_typed_as_a_keyword() {
    for name in ["co llide", "a/b", "tab\\u00a0bed", "\\u3000x y"] {
        let point = format!(r#"{{"kind": "command", "name": "{name}", "permission": "run"}}"#);
        let reason = refusal(&with_point(&point));
        assert!(
            reason.contains("extension_points[].name"),
            "{name}: {reason}"
        );
    }
}

#[test]
fn rejects_a_slash_command_keyword_with_whitespace() {
    let point =
        r#"{"kind": "slash-command", "name": "co llide", "permission": "run", "command": "run"}"#;
    assert!(refusal(&with_point(point)).contains("keyword"));
}

#[test]
fn rejects_a_command_name_over_the_route_limit() {
    let point = format!(
        r#"{{"kind": "command", "name": "{}", "permission": "run"}}"#,
        "x".repeat(65)
    );
    assert!(refusal(&with_point(&point)).contains("extension_points[].name"));
}

#[test]
fn an_app_keeps_a_free_text_label() {
    let app = r#"{"kind": "app", "name": "Game of Life", "permission": "run", "command": "run"}"#;
    assert!(parse_manifest(with_point(app).as_bytes()).is_ok());
}

#[test]
fn rejects_hidden_characters_in_every_displayed_field() {
    let fields = [
        ("\"name\": \"Code Blocks\"", "name"),
        ("\"summary\": \"runs code\"", "summary"),
        ("\"author\": \"slim-m\"", "author"),
        ("\"name\": \"Execute code blocks\"", "permission.name"),
        (
            "\"description\": \"run a snippet\"",
            "permission.description",
        ),
        (
            "\"description\": \"runs it\"",
            "extension_points[].description",
        ),
    ];
    for hidden in ['\u{202E}', '\u{200B}', '\u{061C}', '\u{2066}'] {
        for (needle, field) in fields {
            let poisoned = needle.replacen("\": \"", &format!("\": \"{hidden}"), 1);
            let reason = refusal(&GOOD_MANIFEST.replace(needle, &poisoned));
            assert!(reason.contains(field), "{field} {hidden:?}: {reason}");
        }
    }
}

#[test]
fn rejects_a_hidden_character_in_a_capability() {
    let cap = GOOD_MANIFEST.replace("message.post", "message.\u{200B}post");
    assert!(refusal(&cap).contains("capability"));
}

#[test]
fn rejects_hidden_characters_in_a_registry_index_entry() {
    let bad = GOOD_INDEX.replace("Code Blocks", "Code\u{202E} Blocks");
    assert!(matches!(
        parse_index(bad.as_bytes()),
        Err(ManifestError::Malformed(_))
    ));
}

#[test]
fn an_artifact_path_that_url_join_would_reinterpret_is_refused() {
    for path in [
        "%2e%2e/%2e%2e/bob/evil/main/m.wasm",
        "%2E%2E/m.wasm",
        "\\bob\\evil\\main\\m.wasm",
        "modules//m.wasm",
        "modules/./m.wasm",
        "modules/../m.wasm",
        "./m.wasm",
        "modules/",
        "modules/m.wasm?x=1",
        "modules/m.wasm#x",
        "modules/a:b/m.wasm",
    ] {
        let json_path = path.replace('\\', "\\\\");
        let bad = GOOD_MANIFEST.replace("modules/code-exec/0.1.0/module.wasm", &json_path);
        assert!(
            refusal(&bad).contains("artifact.path"),
            "{path} should be refused"
        );
    }
}

#[test]
fn refuses_a_runtime_backend_the_host_does_not_provide() {
    let reason =
        refusal(&GOOD_MANIFEST.replace(r#""backend": "wasm""#, r#""backend": "container""#));
    assert!(reason.contains("runtime.backend"), "{reason}");
}

#[test]
fn refuses_an_artifact_kind_the_host_cannot_run() {
    let reason = refusal(&GOOD_MANIFEST.replace(r#""kind": "wasm""#, r#""kind": "oci-image""#));
    assert!(reason.contains("artifact.kind"), "{reason}");
}
