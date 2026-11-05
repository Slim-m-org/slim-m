// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a `text` canvas object may carry in its props.

use serde_json::Value;

use crate::hidden_chars::is_hidden_char;

/// Longest text box, in characters; the 4 KiB props ceiling bounds the bytes.
pub const MAX_TEXT_CHARS: usize = 500;

/// The font steps a text box may name; the client maps each onto its type scale.
pub const TEXT_SIZES: [&str; 3] = ["small", "medium", "large"];

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn text_with(color: Value) -> Result<(), &'static str> {
        check_text_props(&json!({"text": "hi", "color": color}))
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
