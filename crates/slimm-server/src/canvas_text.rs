// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a `text` canvas object may carry in its props.

use serde_json::Value;

use crate::hidden_chars::is_hidden_char;

/// Longest text box, in characters; the 4 KiB props ceiling bounds the bytes.
pub const MAX_TEXT_CHARS: usize = 500;

/// The font steps a text box may name; the client maps each onto its type scale.
pub const TEXT_SIZES: [&str; 3] = ["small", "medium", "large"];

const MAX_COLOR_BYTES: usize = 32;

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
        && !color.as_str().is_some_and(|c| {
            !c.is_empty()
                && c.len() <= MAX_COLOR_BYTES
                && c.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        })
    {
        return Err("props.color is not a colour key");
    }
    Ok(())
}
