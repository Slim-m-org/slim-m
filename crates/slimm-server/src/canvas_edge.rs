// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an `edge` canvas object may carry in its props, and the one hull function every client
//! shares (decision 0137).

use serde_json::{Map, Value};

use crate::hidden_chars::hides_text_outside_emoji;
use crate::ids::CanvasObjectId;
use crate::store::WORLD_LIMIT;

/// Longest edge label, in characters.
pub const MAX_LABEL_CHARS: usize = 120;

/// Live edges one object may have attached, so a move or an erase rewrites a bounded number of rows.
pub const MAX_EDGES_PER_OBJECT: i64 = 64;

const SIDES: [&str; 5] = ["auto", "top", "right", "bottom", "left"];
const ARROWS: [&str; 3] = ["none", "end", "both"];
const KEYS: [&str; 5] = ["from", "to", "arrow", "color", "label"];

/// One end of an edge: stuck to an object, or left at a point of the world.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum EdgeEnd {
    Attached(CanvasObjectId),
    Free { x: f64, y: f64 },
}

impl EdgeEnd {
    pub fn attached(self) -> Option<CanvasObjectId> {
        match self {
            EdgeEnd::Attached(id) => Some(id),
            EdgeEnd::Free { .. } => None,
        }
    }
}

/// What the hull of an edge is made of: the box of an attached end, or a free point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HullPart {
    Box { x: f64, y: f64, w: f64, h: f64 },
    Point { x: f64, y: f64 },
}

/// The plain union of the end boxes and points as `(x, y, w, h)`; never clamped.
pub fn edge_hull(parts: &[HullPart]) -> (f64, f64, f64, f64) {
    let (mut min_x, mut min_y) = (f64::INFINITY, f64::INFINITY);
    let (mut max_x, mut max_y) = (f64::NEG_INFINITY, f64::NEG_INFINITY);
    for part in parts {
        let (x0, y0, x1, y1) = match *part {
            HullPart::Box { x, y, w, h } => (x, y, x + w, y + h),
            HullPart::Point { x, y } => (x, y, x, y),
        };
        min_x = min_x.min(x0);
        min_y = min_y.min(y0);
        max_x = max_x.max(x1);
        max_y = max_y.max(y1);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

/// A label of one trimmed, non-empty line that hides nothing; a tab counts as a space.
pub fn check_label(label: &str) -> Result<(), &'static str> {
    if label.trim().is_empty() || label.trim() != label {
        return Err("props.label must be trimmed and not empty");
    }
    if label.chars().count() > MAX_LABEL_CHARS {
        return Err("props.label is too long");
    }
    if label.contains(['\n', '\r']) {
        return Err("props.label must be one line");
    }
    if hides_text_outside_emoji(&label.replace('\t', " ")) {
        return Err("props.label holds hidden characters");
    }
    Ok(())
}

fn parse_end(value: Option<&Value>) -> Result<EdgeEnd, &'static str> {
    let end = value
        .and_then(Value::as_object)
        .ok_or("an edge needs props.from and props.to")?;
    if let Some(raw) = end.get("object_id") {
        if end.keys().any(|k| k != "object_id" && k != "side") {
            return Err("an attached edge end holds only object_id and side");
        }
        if let Some(side) = end.get("side")
            && !side.as_str().is_some_and(|s| SIDES.contains(&s))
        {
            return Err("an edge end side is not known");
        }
        let id = raw
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .ok_or("an edge end object_id is not a valid id")?;
        return Ok(EdgeEnd::Attached(CanvasObjectId(id)));
    }
    if end.keys().any(|k| k != "x" && k != "y") {
        return Err("a free edge end holds only x and y");
    }
    let coord = |key: &str| {
        end.get(key)
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite() && v.abs() <= WORLD_LIMIT)
            .ok_or("a free edge end needs x and y inside the world")
    };
    Ok(EdgeEnd::Free {
        x: coord("x")?,
        y: coord("y")?,
    })
}

/// The ends of an edge whose props passed [`check_edge_props`].
pub fn edge_ends(props: &Value) -> Result<(EdgeEnd, EdgeEnd), &'static str> {
    Ok((parse_end(props.get("from"))?, parse_end(props.get("to"))?))
}

/// The ids an edge's props attach to, read leniently so a stored row that predates a rule still answers.
pub fn attached_ids(props: &Value) -> Vec<CanvasObjectId> {
    ["from", "to"]
        .iter()
        .filter_map(|key| parse_end(props.get(key)).ok()?.attached())
        .collect()
}

/// Refuses props a client could not have produced. Whether the attached objects exist is the store's to check.
pub fn check_edge_props(props: &Value) -> Result<(), &'static str> {
    let object: &Map<String, Value> = props.as_object().ok_or("canvas props must be an object")?;
    if object.keys().any(|k| !KEYS.contains(&k.as_str())) {
        return Err("an edge holds only from, to, arrow, color and label");
    }
    let (from, to) = edge_ends(props)?;
    let (from_id, to_id) = (from.attached(), to.attached());
    if from_id.is_none() && to_id.is_none() {
        return Err("an edge needs at least one end attached to an object");
    }
    if from_id.is_some() && from_id == to_id {
        return Err("an edge cannot join an object to itself");
    }
    if let Some(arrow) = props.get("arrow")
        && !arrow.as_str().is_some_and(|a| ARROWS.contains(&a))
    {
        return Err("props.arrow is not none, end or both");
    }
    if let Some(color) = props.get("color")
        && !color.as_str().is_some_and(crate::canvas_text::is_colour)
    {
        return Err("props.color is not a colour key or #rrggbb");
    }
    if let Some(label) = props.get("label") {
        check_label(label.as_str().ok_or("props.label must be text")?)?;
    }
    Ok(())
}

/// Merges an edit into stored props: an absent key keeps its value and `null` deletes it.
pub fn merge_edge_props(stored: &Value, edit: &Value) -> Value {
    let mut merged = stored.as_object().cloned().unwrap_or_default();
    for (key, value) in edit.as_object().into_iter().flatten() {
        if value.is_null() {
            merged.remove(key);
        } else {
            merged.insert(key.clone(), value.clone());
        }
    }
    Value::Object(merged)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const A: &str = "0190a000-0000-7000-8000-000000000001";
    const B: &str = "0190a000-0000-7000-8000-000000000002";

    fn attached(id: &str) -> Value {
        json!({ "object_id": id, "side": "right" })
    }

    #[test]
    fn a_well_formed_edge_passes() {
        let props = json!({
            "from": attached(A), "to": { "x": 10.0, "y": -4.5 },
            "arrow": "both", "color": "amber", "label": "depends on"
        });
        assert_eq!(check_edge_props(&props), Ok(()));
        assert_eq!(attached_ids(&props).len(), 1);
    }

    #[test]
    fn at_least_one_end_must_be_attached_and_not_to_the_same_object() {
        let free = json!({ "x": 1.0, "y": 2.0 });
        assert!(check_edge_props(&json!({ "from": free, "to": free })).is_err());
        assert!(check_edge_props(&json!({ "from": attached(A), "to": attached(A) })).is_err());
        assert!(check_edge_props(&json!({ "from": attached(A), "to": attached(B) })).is_ok());
    }

    #[test]
    fn malformed_ends_and_stray_keys_are_refused() {
        let ok = attached(A);
        for bad in [
            json!({ "from": ok, "to": { "object_id": "nope" } }),
            json!({ "from": ok, "to": { "object_id": B, "side": "diagonal" } }),
            json!({ "from": ok, "to": { "x": 1.0 } }),
            json!({ "from": ok, "to": { "x": 1.0, "y": 1e12 } }),
            json!({ "from": ok, "to": { "x": 1.0, "y": 1.0, "object_id": B } }),
            json!({ "from": ok, "to": attached(B), "text": "hi" }),
            json!({ "from": ok, "to": attached(B), "arrow": "start" }),
            json!({ "from": ok, "to": attached(B), "color": "not a colour" }),
        ] {
            assert!(check_edge_props(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_label_is_one_trimmed_line_of_at_most_120_characters() {
        assert!(check_label("depends on").is_ok());
        assert!(check_label("two\u{1F468}\u{200D}\u{1F469} people").is_ok());
        for bad in [
            "",
            "  ",
            " padded",
            "two\nlines",
            "zero\u{200B}width",
            &"x".repeat(121),
        ] {
            assert!(check_label(bad).is_err(), "{bad:?}");
        }
        assert!(check_label(&"x".repeat(120)).is_ok());
    }

    #[test]
    fn a_merge_keeps_absent_keys_and_null_deletes() {
        let stored =
            json!({ "from": attached(A), "to": attached(B), "label": "a", "arrow": "end" });
        let merged = merge_edge_props(&stored, &json!({ "label": null, "arrow": "both" }));
        assert_eq!(merged["arrow"], "both");
        assert!(merged.get("label").is_none());
        assert_eq!(merged["from"], stored["from"]);
    }

    #[test]
    fn the_hull_matches_the_shared_vectors() {
        let vectors: Vec<Value> = serde_json::from_str(include_str!(
            "../../../schema/test-vectors/canvas_edge_hull.json"
        ))
        .unwrap();
        assert!(!vectors.is_empty());
        for vector in vectors {
            let parts: Vec<HullPart> = vector["ends"]
                .as_array()
                .unwrap()
                .iter()
                .map(|end| {
                    let n = |v: &Value| v.as_f64().unwrap();
                    if let Some(b) = end.get("box") {
                        HullPart::Box {
                            x: n(&b[0]),
                            y: n(&b[1]),
                            w: n(&b[2]),
                            h: n(&b[3]),
                        }
                    } else {
                        let p = &end["point"];
                        HullPart::Point {
                            x: n(&p[0]),
                            y: n(&p[1]),
                        }
                    }
                })
                .collect();
            let h = &vector["hull"];
            let want: Vec<f64> = (0..4).map(|i| h[i].as_f64().unwrap()).collect();
            let got = edge_hull(&parts);
            assert_eq!(vec![got.0, got.1, got.2, got.3], want, "{}", vector["name"]);
        }
    }
}
