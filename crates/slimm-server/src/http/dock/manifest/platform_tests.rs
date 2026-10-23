// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tests for the module-platform manifest sections of decision 0091.

use serde_json::{Value, json};

use super::tests::GOOD_MANIFEST;
use super::*;

fn manifest_with(extra: Value, caps: &[&str]) -> String {
    let mut m: Value = serde_json::from_str(GOOD_MANIFEST).unwrap();
    let obj = m.as_object_mut().unwrap();
    for (k, v) in extra.as_object().unwrap() {
        obj.insert(k.clone(), v.clone());
    }
    let mut capabilities: Vec<Value> = obj["capabilities"].as_array().unwrap().clone();
    capabilities.extend(caps.iter().map(|c| json!(c)));
    obj.insert("capabilities".into(), Value::Array(capabilities));
    m.to_string()
}

fn refusal(text: &str) -> String {
    match parse_manifest(text.as_bytes()) {
        Err(ManifestError::Malformed(reason)) => reason,
        Ok(_) => panic!("manifest was accepted"),
    }
}

fn ok(extra: Value, caps: &[&str]) -> Manifest {
    parse_manifest(manifest_with(extra, caps).as_bytes()).expect("manifest should parse")
}

fn setting(extra: Value) -> Value {
    let mut base = json!({"key": "k", "type": "int", "label": "K"});
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

fn settings_refusal(entries: Vec<Value>) -> String {
    refusal(&manifest_with(
        json!({"addon_api": 1, "settings": entries}),
        &[],
    ))
}

#[test]
fn an_old_manifest_installs_with_nothing_declared() {
    let m = parse_manifest(GOOD_MANIFEST.as_bytes()).unwrap();
    assert_eq!(m.platform.addon_api, 0);
    assert!(m.platform.subscriptions.is_empty() && m.platform.settings_schema.is_empty());
    assert!(m.platform.slots.is_empty() && m.platform.data_schema.is_null());
}

#[test]
fn an_old_manifest_keeps_its_review_digest() {
    let m = parse_manifest(GOOD_MANIFEST.as_bytes()).unwrap();
    let again = parse_manifest(GOOD_MANIFEST.as_bytes()).unwrap();
    assert_eq!(m.review_digest(), again.review_digest());
    let with_events = ok(
        json!({"addon_api": 1, "subscriptions": [{"event": "member.joined"}]}),
        &["events"],
    );
    assert_ne!(m.review_digest(), with_events.review_digest());
}

#[test]
fn a_higher_addon_api_than_the_host_supports_is_refused_with_a_reason() {
    let reason = refusal(&manifest_with(json!({"addon_api": 2}), &[]));
    assert!(reason.contains("add-on API 2"), "{reason}");
    assert!(parse_manifest(manifest_with(json!({"addon_api": 1}), &[]).as_bytes()).is_ok());
    assert!(refusal(&manifest_with(json!({"addon_api": -1}), &[])).contains("negative"));
}

#[test]
fn using_a_section_without_declaring_addon_api_is_refused() {
    let text = manifest_with(
        json!({"slots": [{"kind": "member.badge", "name": "level"}]}),
        &[],
    );
    assert!(refusal(&text).contains("addon_api"));
}

#[test]
fn subscriptions_need_the_events_capability_and_known_events() {
    let subs = json!({"addon_api": 1, "subscriptions": [{"event": "message.created"}]});
    assert!(refusal(&manifest_with(subs.clone(), &[])).contains("events capability"));
    assert_eq!(
        ok(subs, &["events"]).platform.subscriptions,
        vec!["message.created".to_owned()]
    );
    let unknown = json!({"addon_api": 1, "subscriptions": [{"event": "typing.started"}]});
    assert!(refusal(&manifest_with(unknown, &["events"])).contains("unknown event"));
    let twice = json!({"addon_api": 1, "subscriptions": [{"event": "member.left"}, {"event": "member.left"}]});
    assert!(refusal(&manifest_with(twice, &["events"])).contains("twice"));
}

#[test]
fn at_most_eight_subscriptions() {
    let eight: Vec<Value> = platform::EVENTS
        .iter()
        .cycle()
        .take(9)
        .map(|e| json!({"event": e}))
        .collect();
    let nine = json!({"addon_api": 1, "subscriptions": eight});
    assert!(refusal(&manifest_with(nine, &["events"])).contains("too many subscriptions"));
}

#[test]
fn data_needs_the_data_store_capability_and_is_kept_as_given() {
    let data = json!({"max_mb": 8, "tables": [{"name": "xp", "columns": []}], "future": [1]});
    let declared = json!({"addon_api": 1, "data": data});
    assert!(refusal(&manifest_with(declared.clone(), &[])).contains("data.store"));
    assert_eq!(ok(declared, &["data.store"]).platform.data_schema, data);
}

#[test]
fn slots_are_limited_in_kind_count_and_uniqueness() {
    let slot = |kind: &str, name: &str| json!({"kind": kind, "name": name});
    let good = json!({"addon_api": 1, "slots": [slot("profile.section", "xp"), slot("member.badge", "level")]});
    assert_eq!(ok(good, &[]).platform.slots.len(), 2);
    let bad_kind = json!({"addon_api": 1, "slots": [slot("sidebar.panel", "x")]});
    assert!(refusal(&manifest_with(bad_kind, &[])).contains("slot kind"));
    let dup =
        json!({"addon_api": 1, "slots": [slot("member.badge", "a"), slot("member.badge", "a")]});
    assert!(refusal(&manifest_with(dup, &[])).contains("twice"));
    let five: Vec<Value> = (0..5)
        .map(|i| slot("member.badge", &format!("b{i}")))
        .collect();
    assert!(
        refusal(&manifest_with(json!({"addon_api": 1, "slots": five}), &[]))
            .contains("too many slots")
    );
}

#[test]
fn a_well_formed_settings_list_parses() {
    let list = vec![
        setting(
            json!({"key": "xp_per_minute", "default": 5, "min": 0, "max": 100, "help": "Earned in a call."}),
        ),
        setting(json!({"key": "api_key", "type": "secret"})),
        setting(
            json!({"key": "mode", "type": "choice", "choices": [{"value": "a", "label": "A"}], "default": "a"}),
        ),
        setting(json!({"key": "loud", "type": "bool", "default": true})),
        setting(json!({"key": "greeting", "type": "string", "default": "hi"})),
    ];
    let m = ok(json!({"addon_api": 1, "settings": list}), &[]);
    assert_eq!(m.platform.settings_schema.len(), 5);
}

#[test]
fn settings_enforce_count_keys_and_types() {
    let many: Vec<Value> = (0..33)
        .map(|i| setting(json!({"key": format!("k{i}")})))
        .collect();
    assert!(settings_refusal(many).contains("too many settings"));
    assert!(settings_refusal(vec![setting(json!({})), setting(json!({}))]).contains("duplicate"));
    assert!(settings_refusal(vec![setting(json!({"key": "Bad-Key"}))]).contains("key"));
    assert!(settings_refusal(vec![setting(json!({"type": "float"}))]).contains("invalid manifest"));
}

#[test]
fn settings_enforce_text_lengths() {
    let long_label = "x".repeat(41);
    assert!(settings_refusal(vec![setting(json!({"label": long_label}))]).contains("label"));
    let long_help = "x".repeat(141);
    assert!(settings_refusal(vec![setting(json!({"help": long_help}))]).contains("help"));
}

#[test]
fn settings_enforce_ranges_and_defaults() {
    assert!(settings_refusal(vec![setting(json!({"min": 5, "max": 1}))]).contains("min"));
    assert!(
        settings_refusal(vec![setting(json!({"min": 0, "max": 10, "default": 11}))])
            .contains("default")
    );
    assert!(settings_refusal(vec![setting(json!({"default": "five"}))]).contains("default"));
    assert!(
        settings_refusal(vec![setting(json!({"type": "bool", "min": 1}))]).contains("min or max")
    );
}

#[test]
fn choice_and_secret_settings_enforce_their_own_rules() {
    let choice = |extra: Value| {
        setting(json!({"type": "choice"}))
            .as_object()
            .cloned()
            .map(|mut o| {
                o.extend(extra.as_object().unwrap().clone());
                Value::Object(o)
            })
            .unwrap()
    };
    assert!(settings_refusal(vec![choice(json!({}))]).contains("needs choices"));
    let dup = json!({"choices": [{"value": "a", "label": "A"}, {"value": "a", "label": "B"}]});
    assert!(settings_refusal(vec![choice(dup)]).contains("duplicate choice"));
    let stray = json!({"choices": [{"value": "a", "label": "A"}], "default": "z"});
    assert!(settings_refusal(vec![choice(stray)]).contains("default"));
    let too_many: Vec<Value> = (0..17)
        .map(|i| json!({"value": format!("v{i}"), "label": "L"}))
        .collect();
    assert!(
        settings_refusal(vec![choice(json!({"choices": too_many}))]).contains("too many choices")
    );
    assert!(
        settings_refusal(vec![setting(json!({"type": "secret", "default": "x"}))])
            .contains("secret")
    );
    assert!(
        settings_refusal(vec![setting(
            json!({"type": "int", "choices": [{"value": "a", "label": "A"}]})
        )])
        .contains("choices")
    );
}
