// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the review digest covers: a change to anything an admin consents to
//! must change it, and listing the same things in another order must not.

use serde_json::{Value, json};

use super::super::parse_manifest;
use super::super::tests::GOOD_MANIFEST;

const HOOK_CAPS: [&str; 2] = ["interceptors", "permission.hook"];

fn manifest(edit: impl FnOnce(&mut serde_json::Map<String, Value>)) -> Value {
    let mut m: Value = serde_json::from_str(GOOD_MANIFEST).unwrap();
    let obj = m.as_object_mut().unwrap();
    obj.insert("addon_api".into(), json!(3));
    let caps = obj["capabilities"].as_array_mut().unwrap();
    caps.extend(HOOK_CAPS.iter().map(|c| json!(c)));
    edit(obj);
    m
}

fn digest(m: &Value) -> String {
    parse_manifest(m.to_string().as_bytes())
        .expect("the manifest should parse")
        .review_digest()
}

fn with_interceptor(phase: &str, reads: &[&str]) -> Value {
    manifest(|m| {
        m.insert(
            "interceptors".into(),
            json!([{"hook": "message.pre_send", "phase": phase, "reads": reads}]),
        );
    })
}

#[test]
fn an_interceptor_moving_to_a_stronger_phase_changes_the_digest() {
    let annotate = digest(&with_interceptor("annotate", &["content"]));
    let rewrite = digest(&with_interceptor("rewrite", &["content"]));
    assert_ne!(annotate, rewrite);
}

#[test]
fn an_interceptor_reading_more_changes_the_digest() {
    let narrow = digest(&with_interceptor("annotate", &[]));
    let wide = digest(&with_interceptor("annotate", &["content"]));
    assert_ne!(narrow, wide);
}

#[test]
fn a_permission_hook_added_or_moved_changes_the_digest() {
    let hook = |action: &str| {
        manifest(|m| {
            m.insert(
                "permission_hooks".into(),
                json!([{"action": action, "reads": []}]),
            );
        })
    };
    let none = digest(&manifest(|_| {}));
    let send = digest(&hook("message.send"));
    let join = digest(&hook("voice.join"));
    assert!(none != send && send != join && none != join);
}

#[test]
fn the_order_hooks_are_listed_in_does_not_change_the_digest() {
    let hooks = |first: &str, second: &str| {
        manifest(|m| {
            m.insert(
                "interceptors".into(),
                json!([
                    {"hook": "message.pre_send", "phase": first, "reads": ["content", "is_bot"]},
                    {"hook": "message.pre_edit", "phase": second, "reads": []},
                ]),
            );
        })
    };
    let a = digest(&hooks("annotate", "reject"));
    let swapped = manifest(|m| {
        m.insert(
            "interceptors".into(),
            json!([
                {"hook": "message.pre_edit", "phase": "reject", "reads": []},
                {"hook": "message.pre_send", "phase": "annotate", "reads": ["is_bot", "content"]},
            ]),
        );
    });
    assert_eq!(a, digest(&swapped));
    assert_ne!(a, digest(&hooks("rewrite", "reject")));
}

fn with_extension_point(point: Value) -> Value {
    with_extension_points(vec![point])
}

fn with_extension_points(points: Vec<Value>) -> Value {
    manifest(|m| {
        m.insert(
            "permissions".into(),
            json!([
                {"key": "run", "name": "Run", "description": "run a snippet"},
                {"key": "admin", "name": "Admin", "description": "manage it"},
            ]),
        );
        m.insert("extension_points".into(), json!(points));
    })
}

#[test]
fn a_renamed_or_retargeted_extension_point_changes_the_digest() {
    let run = json!({"kind": "command", "name": "run", "permission": "run"});
    let renamed = json!({"kind": "command", "name": "ban", "permission": "run"});
    let retargeted = json!({"kind": "command", "name": "run", "permission": "admin"});
    let base = digest(&with_extension_point(run));
    assert_ne!(base, digest(&with_extension_point(renamed)));
    assert_ne!(base, digest(&with_extension_point(retargeted)));
}

#[test]
fn an_added_extension_point_changes_the_digest() {
    let one = json!({"kind": "command", "name": "run", "permission": "run"});
    let two = json!({"kind": "command", "name": "stop", "permission": "run"});
    let base = digest(&with_extension_point(one.clone()));
    let both = digest(&with_extension_points(vec![one, two]));
    assert_ne!(base, both);
}

#[test]
fn a_changed_setting_or_slot_changes_the_digest() {
    let setting = |key: &str, kind: &str| {
        manifest(|m| {
            m.insert(
                "settings".into(),
                json!([{"key": key, "type": kind, "label": "K"}]),
            );
        })
    };
    let base = digest(&setting("limit", "int"));
    assert_ne!(base, digest(&setting("cap", "int")));
    assert_ne!(base, digest(&setting("limit", "string")));

    let slot = |name: &str| {
        manifest(|m| {
            m.insert(
                "slots".into(),
                json!([{"kind": "member.badge", "name": name}]),
            );
        })
    };
    assert_ne!(digest(&slot("level")), digest(&slot("rank")));
    assert_ne!(digest(&slot("level")), digest(&manifest(|_| {})));
}

#[test]
fn a_secrets_allowed_hosts_are_part_of_the_digest() {
    let secret = |hosts: &[&str]| {
        manifest(|m| {
            m.get_mut("capabilities")
                .unwrap()
                .as_array_mut()
                .unwrap()
                .push(json!("net.fetch"));
            m.insert(
                "network".into(),
                json!({"hosts": ["api.example.com", "other.example.com"]}),
            );
            m.insert(
                "settings".into(),
                json!([{"key": "token", "type": "secret", "label": "Token", "hosts": hosts}]),
            );
        })
    };
    let one = digest(&secret(&["api.example.com"]));
    let other = digest(&secret(&["other.example.com"]));
    assert_ne!(one, other);
}

const IMAGE_A: &str =
    "ghcr.io/slim-m-org/x@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const IMAGE_B: &str =
    "ghcr.io/slim-m-org/x@sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

fn connector(host_run: Value) -> Value {
    json!({
        "schema": 1, "id": "jellyfin", "name": "Jellyfin", "version": "0.1.0",
        "summary": "posts what is playing", "provider": "connector", "addon_api": 7,
        "connector": {"permissions": ["send_messages"], "host_run": host_run}
    })
}

#[test]
fn any_change_to_a_host_run_ask_changes_the_digest() {
    let base = json!({"image": IMAGE_A, "egress": [{"host": "a.example.com", "port": 443}]});
    let reference = digest(&connector(base.clone()));
    let edits = [
        json!({"image": IMAGE_B}),
        json!({"volume": true}),
        json!({"egress_private": true}),
        json!({"egress": [{"host": "a.example.com", "port": 8443}]}),
        json!({"limits": {"memory_mib": 512}}),
        json!({"limits": {"cpus": 1.0}}),
        json!({"limits": {"pids": 512}}),
        json!({"limits": {"volume_mib": 512}}),
    ];
    for edit in edits {
        let mut ask = base.clone();
        ask.as_object_mut()
            .unwrap()
            .extend(edit.as_object().unwrap().clone());
        assert_ne!(digest(&connector(ask)), reference, "{edit}");
    }
}

#[test]
fn a_host_run_egress_listed_in_another_order_keeps_the_digest() {
    let a = json!({"image": IMAGE_A, "egress": [{"host": "a.example.com", "port": 443}, {"host": "b.example.com", "port": 443}]});
    let b = json!({"image": IMAGE_A, "egress": [{"host": "b.example.com", "port": 443}, {"host": "a.example.com", "port": 443}]});
    assert_eq!(digest(&connector(a)), digest(&connector(b)));
}

#[test]
fn rewording_a_permission_or_an_extension_point_changes_the_digest() {
    let reference = digest(&manifest(|_| {}));
    let reworded = |from: &str, to: &str| {
        let text = GOOD_MANIFEST.replace(from, to);
        let mut m: Value = serde_json::from_str(&text).unwrap();
        m.as_object_mut()
            .unwrap()
            .insert("addon_api".into(), json!(3));
        m["capabilities"]
            .as_array_mut()
            .unwrap()
            .extend(HOOK_CAPS.iter().map(|c| json!(c)));
        digest(&m)
    };
    assert_ne!(reworded("Execute code blocks", "Read messages"), reference);
    assert_ne!(reworded("run a snippet", "harmless"), reference);
    assert_ne!(reworded("runs it", "does nothing"), reference);
}
