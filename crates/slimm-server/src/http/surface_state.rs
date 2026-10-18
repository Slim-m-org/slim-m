// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An interactive scene hands its module `{"action", "state"}` on each press.
//! For a surface everyone shares, the `state` comes from the last scene the
//! server stored, never from whoever pressed, so a client cannot forge a board
//! (seat a player, end a game, read an answer it was never told).

use serde_json::{Map, Value};

/// `input` with its `state` replaced by the one in `stored_scene`, or removed
/// when the stored scene carries none. An input that is not an action frame
/// (a launch's empty input, plain text) is returned unchanged.
pub(super) fn with_held_state(input: &str, stored_scene: Option<&str>) -> String {
    let Ok(Value::Object(mut frame)) = serde_json::from_str::<Value>(input) else {
        return input.to_owned();
    };
    if !frame.contains_key("action") {
        return input.to_owned();
    }
    match stored_scene.and_then(held_state) {
        Some(state) => frame.insert("state".to_owned(), Value::String(state)),
        None => frame.remove("state"),
    };
    serde_json::to_string(&Value::Object(Map::from_iter(frame)))
        .unwrap_or_else(|_| input.to_owned())
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
    fn anything_that_is_not_an_action_frame_passes_through() {
        for input in ["", "hello", r#"{"x":1}"#, "[1]"] {
            assert_eq!(with_held_state(input, Some(STORED)), input);
        }
    }
}
