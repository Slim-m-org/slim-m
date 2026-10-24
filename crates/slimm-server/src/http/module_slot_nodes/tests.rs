// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

use serde_json::{Value, json};

use super::*;

fn item(nodes: Value) -> Option<SlotItem> {
    sanitize_item(&json!({ "nodes": nodes }))
}

fn nodes_of(nodes: Value) -> Vec<Value> {
    item(nodes).map(|i| i.nodes).unwrap_or_default()
}

fn text(s: &str) -> Value {
    json!({ "type": "text", "text": s })
}

fn nested(levels: usize) -> Value {
    let mut node = text("leaf");
    for _ in 1..levels {
        node = json!({ "type": "stack", "children": [node] });
    }
    node
}

#[test]
fn every_node_type_passes_and_is_rebuilt_from_known_fields() {
    let tree = json!([
        { "type": "text", "text": "Level 4", "tone": "accent", "extra": 1 },
        { "type": "icon", "name": "play" },
        { "type": "badge", "text": "VIP", "icon": "list", "tone": "muted" },
        { "type": "progress", "value": 30, "max": 100, "label": "xp" },
        { "type": "row", "children": [text("a"), { "type": "stack", "children": [text("b")] }] },
    ]);
    let got = nodes_of(tree);
    assert_eq!(got.len(), 5);
    assert_eq!(
        got[0],
        json!({ "type": "text", "text": "Level 4", "tone": "accent" })
    );
    assert_eq!(got[3]["value"], json!(30));
    assert_eq!(got[4]["children"][1]["children"][0]["text"], "b");
}

#[test]
fn more_than_forty_nodes_drops_the_tree_and_forty_pass() {
    let forty: Vec<Value> = (0..40).map(|_| text("x")).collect();
    assert_eq!(nodes_of(json!(forty)).len(), 40);
    let forty_one: Vec<Value> = (0..41).map(|_| text("x")).collect();
    assert!(item(json!(forty_one)).is_none());
}

#[test]
fn nodes_nested_in_containers_count_toward_the_forty() {
    let children: Vec<Value> = (0..40).map(|_| text("x")).collect();
    let tree = json!([{ "type": "row", "children": children }]);
    assert!(item(tree).is_none(), "41 with the row itself");
}

#[test]
fn depth_four_passes_and_depth_five_drops_the_tree() {
    assert_eq!(nodes_of(json!([nested(4)])).len(), 1);
    assert!(item(json!([nested(5)])).is_none());
}

#[test]
fn a_deep_tree_keeps_its_fallback() {
    let got = sanitize_item(&json!({ "nodes": [nested(5)], "fallback": "Level 4" })).unwrap();
    assert!(got.nodes.is_empty());
    assert_eq!(got.fallback.as_deref(), Some("Level 4"));
}

#[test]
fn text_over_120_characters_drops_the_node_and_120_passes() {
    assert_eq!(nodes_of(json!([text(&"a".repeat(120))])).len(), 1);
    assert!(item(json!([text(&"a".repeat(121))])).is_none());
}

#[test]
fn badge_text_over_24_characters_drops_the_node() {
    let badge = |s: &str| json!([{ "type": "badge", "text": s }]);
    assert_eq!(nodes_of(badge(&"a".repeat(24))).len(), 1);
    assert!(item(badge(&"a".repeat(25))).is_none());
}

#[test]
fn a_tone_outside_the_closed_set_drops_the_node() {
    let tone = |t: &str| json!([{ "type": "text", "text": "x", "tone": t }]);
    assert_eq!(nodes_of(tone("muted")).len(), 1);
    assert!(item(tone("danger")).is_none());
    let badge = json!([{ "type": "badge", "text": "x", "tone": "red" }]);
    assert!(item(badge).is_none());
}

#[test]
fn an_icon_must_come_from_the_closed_list() {
    assert_eq!(
        nodes_of(json!([{ "type": "icon", "name": "settings" }])).len(),
        1
    );
    assert!(item(json!([{ "type": "icon", "name": "skull" }])).is_none());
    assert!(item(json!([{ "type": "badge", "text": "x", "icon": "skull" }])).is_none());
}

#[test]
fn an_unknown_type_is_dropped_and_its_siblings_stay() {
    let got = nodes_of(json!([{ "type": "button", "text": "x" }, text("kept")]));
    assert_eq!(got, vec![text("kept")]);
}

#[test]
fn an_unknown_type_alone_is_dropped_without_a_fallback_and_kept_with_one() {
    let unknown = json!([{ "type": "chart" }]);
    assert!(item(unknown.clone()).is_none());
    let got = sanitize_item(&json!({ "nodes": unknown, "fallback": "Level 4" })).unwrap();
    assert!(got.nodes.is_empty());
    assert_eq!(got.fallback.as_deref(), Some("Level 4"));
}

#[test]
fn a_fallback_alone_makes_an_item_and_is_capped_at_120() {
    let ok = sanitize_item(&json!({ "fallback": "x".repeat(120) })).unwrap();
    assert_eq!(ok.fallback.as_ref().map(String::len), Some(120));
    assert!(sanitize_item(&json!({ "fallback": "x".repeat(121) })).is_none());
}

#[test]
fn progress_clamps_value_and_needs_a_positive_max() {
    let p = |v: Value, m: Value| json!([{ "type": "progress", "value": v, "max": m }]);
    assert_eq!(nodes_of(p(json!(250), json!(100)))[0]["value"], json!(100));
    assert_eq!(nodes_of(p(json!(-5), json!(100)))[0]["value"], json!(0));
    assert_eq!(nodes_of(p(json!(0.5), json!(2)))[0]["value"], json!(0.5));
    assert!(item(p(json!(1), json!(0))).is_none());
    assert!(item(p(json!(1), json!(-3))).is_none());
    assert!(item(p(json!("1"), json!(3))).is_none());
    assert!(item(json!([{ "type": "progress", "max": 3 }])).is_none());
}

#[test]
fn hidden_and_bidi_characters_are_stripped() {
    let got = nodes_of(json!([text("Le\u{202E}vel\u{200B} 4\u{0007}")]));
    assert_eq!(got[0]["text"], "Level 4");
    let got = sanitize_item(&json!({ "fallback": "a\u{2066}b" })).unwrap();
    assert_eq!(got.fallback.as_deref(), Some("ab"));
}

#[test]
fn text_that_is_only_hidden_characters_is_dropped() {
    assert!(item(json!([text("\u{200B}\u{3164}")])).is_none());
}

#[test]
fn an_empty_container_is_dropped() {
    assert!(item(json!([{ "type": "row", "children": [] }])).is_none());
    assert!(item(json!([{ "type": "row" }])).is_none());
}

#[test]
fn the_response_needs_the_slot_one_marker_and_only_wanted_ids_pass() {
    let (ada, bob) = (UserId::generate(), UserId::generate());
    let body = |marker: &str| {
        json!({
            "$slim": marker,
            "items": {
                ada.to_string(): { "nodes": [text("a")] },
                bob.to_string(): { "nodes": [text("b")] },
            }
        })
        .to_string()
    };
    let got = parse_response(&body("slot/1"), &[ada]).unwrap();
    assert_eq!(got.len(), 1);
    assert!(got.contains_key(&ada));
    assert!(parse_response(&body("slot/2"), &[ada]).is_none());
    assert!(parse_response("not json", &[ada]).is_none());
    assert!(parse_response("[]", &[ada]).is_none());
}
