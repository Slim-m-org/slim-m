// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An interactive scene hands its module `{"action", "state"}` on each press.
//! For a surface everyone shares, the `state` comes from the last scene the
//! server stored, never from whoever pressed, so a client cannot forge a board
//! (seat a player, end a game, read an answer it was never told).
//!
//! Once a surface has a stored frame, a press that names no action is a redraw
//! of that frame. Only a surface with nothing stored yet is launched, so a
//! stray or stale launch cannot replace the board everyone is looking at.

use serde_json::{Map, Value, json};

/// The action a press without one is turned into once a frame is stored.
pub(super) const REDRAW_ACTION: &str = "refresh";

/// The input a surface's module is run with. With a stored frame, the module
/// always gets an action frame whose `state` is that frame's (or none when the
/// frame carries none), and the client's own `state` is never passed on.
/// With nothing stored, an action frame loses its `state` and anything else
/// (a launch's empty input) is returned unchanged.
pub(super) fn with_held_state(input: &str, stored_scene: Option<&str>) -> String {
    let parsed = serde_json::from_str::<Value>(input);
    let has_action = matches!(&parsed, Ok(Value::Object(frame)) if frame.contains_key("action"));
    if stored_scene.is_none() && !has_action {
        return input.to_owned();
    }
    let mut frame = match parsed {
        Ok(Value::Object(frame)) if has_action => frame,
        _ => Map::from_iter([("action".to_owned(), json!(REDRAW_ACTION))]),
    };
    match stored_scene.and_then(held_state) {
        Some(state) => frame.insert("state".to_owned(), Value::String(state)),
        None => frame.remove("state"),
    };
    serde_json::to_string(&Value::Object(frame)).unwrap_or_else(|_| input.to_owned())
}

fn held_state(stored_scene: &str) -> Option<String> {
    let scene: Value = serde_json::from_str(stored_scene).ok()?;
    scene.get("state")?.as_str().map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    const STORED: &str = r#"{"$slim":"scene/1","ops":[],"state":"real"}"#;

    fn state_of(input: &str) -> Option<String> {
        serde_json::from_str::<Value>(input)
            .ok()?
            .get("state")?
            .as_str()
            .map(str::to_owned)
    }

    #[test]
    fn a_forged_state_is_replaced_by_the_stored_one() {
        let out = with_held_state(r#"{"action":"toggle:0,1","state":"forged"}"#, Some(STORED));
        assert_eq!(state_of(&out).as_deref(), Some("real"));
        assert!(out.contains("toggle:0,1"));
    }

    #[test]
    fn a_state_with_nothing_stored_is_dropped() {
        let out = with_held_state(r#"{"action":"step","state":"forged"}"#, None);
        assert_eq!(state_of(&out), None);
        let out = with_held_state(r#"{"action":"step","state":"forged"}"#, Some("not json"));
        assert_eq!(state_of(&out), None);
    }

    #[test]
    fn a_state_is_added_when_the_client_sent_none() {
        let out = with_held_state(r#"{"action":"step"}"#, Some(STORED));
        assert_eq!(state_of(&out).as_deref(), Some("real"));
    }

    #[test]
    fn nothing_that_is_not_an_action_frame_changes_while_nothing_is_stored() {
        for input in ["", "hello", r#"{"x":1}"#, "[1]"] {
            assert_eq!(with_held_state(input, None), input);
        }
    }

    #[test]
    fn a_press_without_an_action_redraws_the_stored_frame() {
        for input in ["", "hello", r#"{"x":1}"#, "[1]", r#"{"state":"forged"}"#] {
            let out = with_held_state(input, Some(STORED));
            assert_eq!(state_of(&out).as_deref(), Some("real"), "{input}");
            assert!(out.contains(r#""action":"refresh""#), "{input}: {out}");
        }
    }
}
