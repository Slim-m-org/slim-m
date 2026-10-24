// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Validating what a module returns for a slot (`slot/1`, decision 0091). The
//! host rebuilds every node from known fields, so nothing a module adds reaches
//! a client, and a violation drops the thing it applies to rather than trusting
//! the client to cope.

use std::collections::HashMap;

use serde_json::{Map, Value, json};

use crate::bot_ui::CALL_ICONS;
use crate::hidden_chars::is_hidden_char;
use crate::ids::UserId;

const MAX_NODES: usize = 40;
const MAX_DEPTH: usize = 4;
const MAX_TEXT: usize = 120;
const MAX_BADGE_TEXT: usize = 24;
const TONES: [&str; 3] = ["normal", "muted", "accent"];

/// One member's slot content: the nodes that passed, and a plain-text fallback.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct SlotItem {
    pub(crate) nodes: Vec<Value>,
    pub(crate) fallback: Option<String>,
}

/// The items a `slot/1` response holds for `wanted`; `None` when it is not a `slot/1` response.
pub(crate) fn parse_response(output: &str, wanted: &[UserId]) -> Option<HashMap<UserId, SlotItem>> {
    let Ok(Value::Object(root)) = serde_json::from_str::<Value>(output) else {
        return None;
    };
    if root.get("$slim").and_then(Value::as_str) != Some("slot/1") {
        return None;
    }
    let Some(Value::Object(items)) = root.get("items") else {
        return None;
    };
    Some(
        wanted
            .iter()
            .filter_map(|id| {
                let item = sanitize_item(items.get(&id.to_string())?)?;
                Some((*id, item))
            })
            .collect(),
    )
}

/// The item a module returned for one member, or `None` when nothing is left to show.
pub(crate) fn sanitize_item(raw: &Value) -> Option<SlotItem> {
    let raw = raw.as_object()?;
    let fallback = raw.get("fallback").and_then(|v| clean(v, MAX_TEXT));
    let nodes = raw
        .get("nodes")
        .and_then(Value::as_array)
        .and_then(|nodes| sanitize_tree(nodes))
        .unwrap_or_default();
    if nodes.is_empty() && fallback.is_none() {
        return None;
    }
    Some(SlotItem { nodes, fallback })
}

/// `None` when the tree breaks a size limit, which drops all of it.
fn sanitize_tree(nodes: &[Value]) -> Option<Vec<Value>> {
    let mut seen = 0;
    sanitize_nodes(nodes, 1, &mut seen)
}

fn sanitize_nodes(nodes: &[Value], depth: usize, seen: &mut usize) -> Option<Vec<Value>> {
    if depth > MAX_DEPTH {
        return None;
    }
    let mut kept = Vec::new();
    for raw in nodes {
        *seen += 1;
        if *seen > MAX_NODES {
            return None;
        }
        if let Some(node) = sanitize_node(raw, depth, seen)? {
            kept.push(node);
        }
    }
    Some(kept)
}

/// Outer `None` is a size violation; inner `None` is a node that is simply dropped.
fn sanitize_node(raw: &Value, depth: usize, seen: &mut usize) -> Option<Option<Value>> {
    let Some(node) = raw.as_object() else {
        return Some(None);
    };
    Some(match node.get("type").and_then(Value::as_str) {
        Some("text") => text_node(node),
        Some("icon") => icon_node(node),
        Some("badge") => badge_node(node),
        Some("progress") => progress_node(node),
        Some(kind @ ("row" | "stack")) => {
            let children = node.get("children").and_then(Value::as_array);
            let kept = sanitize_nodes(children.map_or(&[], Vec::as_slice), depth + 1, seen)?;
            (!kept.is_empty()).then(|| json!({ "type": kind, "children": kept }))
        }
        _ => None,
    })
}

fn text_node(node: &Map<String, Value>) -> Option<Value> {
    let text = clean(node.get("text")?, MAX_TEXT)?;
    let mut out = json!({ "type": "text", "text": text });
    add_tone(&mut out, node)?;
    Some(out)
}

fn icon_node(node: &Map<String, Value>) -> Option<Value> {
    Some(json!({ "type": "icon", "name": icon_name(node.get("name")?)? }))
}

fn badge_node(node: &Map<String, Value>) -> Option<Value> {
    let mut out = json!({ "type": "badge", "text": clean(node.get("text")?, MAX_BADGE_TEXT)? });
    if let Some(icon) = node.get("icon") {
        out["icon"] = json!(icon_name(icon)?);
    }
    add_tone(&mut out, node)?;
    Some(out)
}

fn progress_node(node: &Map<String, Value>) -> Option<Value> {
    let max = node.get("max")?.as_f64().filter(|m| *m > 0.0)?;
    let value = node.get("value")?.as_f64()?.clamp(0.0, max);
    let mut out = json!({ "type": "progress", "value": number(value), "max": number(max) });
    if let Some(label) = node.get("label") {
        out["label"] = json!(clean(label, MAX_TEXT)?);
    }
    Some(out)
}

/// Whole numbers stay integers on the wire.
fn number(n: f64) -> Value {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        json!(n as i64)
    } else {
        json!(n)
    }
}

/// Copies a valid `tone` onto `out`; `None` when the node set one that is not allowed.
fn add_tone(out: &mut Value, node: &Map<String, Value>) -> Option<()> {
    if let Some(tone) = node.get("tone") {
        let tone = tone.as_str().filter(|t| TONES.contains(t))?;
        out["tone"] = json!(tone);
    }
    Some(())
}

fn icon_name(raw: &Value) -> Option<&str> {
    raw.as_str().filter(|name| CALL_ICONS.contains(name))
}

/// `raw` without hidden characters, or `None` when empty or over `max` characters.
fn clean(raw: &Value, max: usize) -> Option<String> {
    let text: String = raw
        .as_str()?
        .chars()
        .filter(|c| !is_hidden_char(*c))
        .collect();
    let text = text.trim();
    (!text.is_empty() && text.chars().count() <= max).then(|| text.to_owned())
}

#[cfg(test)]
mod tests;
