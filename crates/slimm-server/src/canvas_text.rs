// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a `text` canvas object may carry in its props.

use serde_json::Value;

use crate::hidden_chars::is_hidden_char;

/// Longest text box, in characters; the 4 KiB props ceiling bounds the bytes.
pub const MAX_TEXT_CHARS: usize = 500;

/// The font steps a text box may name; the client maps each onto its type scale.
pub const TEXT_SIZES: [&str; 3] = ["small", "medium", "large"];

/// Largest serialized `props` one canvas object may carry.
pub const MAX_PROPS_BYTES: usize = 4 * 1024;

const MAX_COLOR_BYTES: usize = 32;

/// A named colour key of identifier characters, or `#rrggbb`: the one rule for every canvas colour.
pub fn is_colour(c: &str) -> bool {
    if let Some(hex) = c.strip_prefix('#') {
        return hex.len() == 6 && hex.bytes().all(|b| b.is_ascii_hexdigit());
    }
    !c.is_empty()
        && c.len() <= MAX_COLOR_BYTES
        && c.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Refuses props a client could not have produced: wrong types, an empty or oversized text, hidden characters, an unknown size.
///
/// A line break is the one control character allowed, since it is what a text box wraps on.
pub fn check_text_props(props: &Value) -> Result<(), &'static str> {
    let Some(text) = props.get("text").and_then(Value::as_str) else {
        return Err("a text object needs props.text");
    };
    if text.trim().is_empty() {
        return Err("props.text must not be empty");
    }
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err("props.text is too long");
    }
    if text.chars().any(|c| c != '\n' && is_hidden_char(c)) {
        return Err("props.text holds hidden characters");
    }
    if let Some(size) = props.get("size")
        && !size.as_str().is_some_and(|s| TEXT_SIZES.contains(&s))
    {
        return Err("props.size is not a known text size");
    }
    if let Some(color) = props.get("color")
        && !color.as_str().is_some_and(is_colour)
    {
        return Err("props.color is not a colour key or #rrggbb");
    }
    Ok(())
}

/// Refuses note props that carry a known key of the wrong type; every other key, `font_size` included, passes.
///
/// Notes took any props before the style keys existed, so `text` is only required to be a string.
pub fn check_note_props(props: &Value) -> Result<(), &'static str> {
    let known = |key: &str| props.get(key).filter(|v| !v.is_null());
    if props.get("text").is_some_and(|t| !t.is_string()) {
        return Err("props.text must be a string");
    }
    for key in ["fill", "color"] {
        if known(key).is_some_and(|v| !v.as_str().is_some_and(is_colour)) {
            return Err("a note colour is a colour key or #rrggbb");
        }
    }
    if known("size").is_some_and(|v| !v.as_str().is_some_and(|s| TEXT_SIZES.contains(&s))) {
        return Err("props.size is not a known text size");
    }
    if known("fill_opacity").is_some_and(|v| {
        !v.as_f64()
            .is_some_and(|n| n.is_finite() && (0.0..=1.0).contains(&n))
    }) {
        return Err("props.fill_opacity must be a number from 0 to 1");
    }
    Ok(())
}

/// An edit laid over the stored props: an absent key keeps its value and `null` deletes the key.
pub fn merge_props(stored: &Value, edit: &Value) -> Value {
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

    fn text_with(color: Value) -> Result<(), &'static str> {
        check_text_props(&json!({"text": "hi", "color": color}))
    }

    #[test]
    fn a_note_keeps_every_prop_an_older_client_sends() {
        for ok in [
            json!({"text": "a", "font_size": 14.0}),
            json!({"text": "a"}),
            json!({"text": "a", "color": "annotation", "unknown": [1]}),
            json!({"fill": null, "fill_opacity": null, "color": null, "size": null}),
            json!({"fill": "#ff8800", "fill_opacity": 0.0, "color": "auto", "size": "large"}),
            json!({"text": "family \u{1F468}\u{200D}\u{1F469}\t\r\n"}),
        ] {
            assert!(check_note_props(&ok).is_ok(), "{ok}");
        }
    }

    #[test]
    fn a_note_refuses_a_known_key_of_the_wrong_type() {
        for bad in [
            json!({"text": 4}),
            json!({"fill": "#fff"}),
            json!({"color": 3}),
            json!({"size": "huge"}),
            json!({"fill_opacity": -0.1}),
            json!({"fill_opacity": 1.5}),
            json!({"fill_opacity": "x"}),
        ] {
            assert!(check_note_props(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn merging_keeps_absent_keys_and_null_deletes() {
        let merged = merge_props(
            &json!({"text": "a", "fill": "blue", "size": "large"}),
            &json!({"text": "b", "size": null, "color": "green"}),
        );
        assert_eq!(
            merged,
            json!({"text": "b", "fill": "blue", "color": "green"})
        );
    }

    #[test]
    fn a_text_colour_is_a_key_or_a_six_digit_hex() {
        for ok in ["annotation", "amber", "pen-2", "#ff8800", "#FF8800"] {
            assert!(text_with(json!(ok)).is_ok(), "{ok}");
        }
        for bad in ["", "#fff", "#ff88001", "#gg0000", "a b", "#", "rgb(1,2,3)"] {
            assert!(text_with(json!(bad)).is_err(), "{bad}");
        }
        assert!(text_with(json!(7)).is_err());
        assert!(text_with(json!("a".repeat(33))).is_err());
    }
}
