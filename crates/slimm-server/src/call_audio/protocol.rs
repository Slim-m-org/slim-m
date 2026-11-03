// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `listener/1` messages between the server and the call-audio listener
//! (decision 0105). Every frame is a JSON object with `"v": 1` and a `"type"`.
//! The listener has its own copy of these types; both parse the fixtures in
//! `crates/slimm-listener/protocol/` so they cannot drift apart.

use serde::{Deserialize, Serialize};

/// The protocol version this side speaks.
pub const VERSION: u64 = 1;

/// What the server sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Tagged by `type`.
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToListener {
    Start {
        session: String,
        livekit_url: String,
        token: String,
        include: Vec<String>,
        language: Option<String>,
    },
    /// The whole set, never a delta, so a lost frame cannot leave someone included.
    Include {
        session: String,
        include: Vec<String>,
    },
    Stop {
        session: String,
    },
}

/// What the listener sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
/// Tagged by `type`.
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FromListener {
    Ready {
        version: String,
        engine: String,
        model: String,
        max_sessions: u32,
    },
    Started {
        session: String,
    },
    Segment {
        session: String,
        identity: String,
        start_ms: i64,
        end_ms: i64,
        text: String,
        language: Option<String>,
    },
    Ended {
        session: String,
        reason: String,
    },
}

/// Why a received frame was not usable.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// A newer protocol version: the connection should close.
    Newer(u64),
    Malformed(String),
}

/// `message` as a frame carrying `"v": 1`.
pub fn encode(message: &ToListener) -> String {
    let mut value = serde_json::to_value(message).unwrap_or_default();
    if let Some(object) = value.as_object_mut() {
        object.insert("v".into(), VERSION.into());
    }
    value.to_string()
}

/// Parses one frame from the listener.
pub fn decode(text: &str) -> Result<FromListener, DecodeError> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| DecodeError::Malformed(e.to_string()))?;
    match value.get("v").and_then(serde_json::Value::as_u64) {
        Some(VERSION) => {}
        Some(newer) if newer > VERSION => return Err(DecodeError::Newer(newer)),
        _ => return Err(DecodeError::Malformed("missing or unknown v".into())),
    }
    serde_json::from_value(value).map_err(|e| DecodeError::Malformed(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../slimm-listener/protocol");

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{FIXTURES}/{name}.json")).expect("fixture exists")
    }

    #[test]
    fn every_listener_fixture_parses() {
        for name in ["ready", "started", "segment", "ended"] {
            decode(&fixture(name)).unwrap_or_else(|e| panic!("{name}: {e:?}"));
        }
    }

    #[test]
    fn every_server_fixture_matches_what_the_server_sends() {
        let cases = [
            (
                "start",
                ToListener::Start {
                    session: "s1".into(),
                    livekit_url: "ws://livekit:7880".into(),
                    token: "jwt".into(),
                    include: vec!["u1".into(), "u2".into()],
                    language: None,
                },
            ),
            (
                "include",
                ToListener::Include {
                    session: "s1".into(),
                    include: vec!["u1".into()],
                },
            ),
            (
                "stop",
                ToListener::Stop {
                    session: "s1".into(),
                },
            ),
        ];
        for (name, message) in cases {
            let sent: serde_json::Value = serde_json::from_str(&encode(&message)).unwrap();
            let expected: serde_json::Value = serde_json::from_str(&fixture(name)).unwrap();
            assert_eq!(sent, expected, "{name}");
        }
    }

    #[test]
    fn a_newer_version_is_told_apart_from_garbage() {
        assert_eq!(
            decode(r#"{"v":2,"type":"started","session":"s"}"#),
            Err(DecodeError::Newer(2))
        );
        assert!(matches!(decode("nope"), Err(DecodeError::Malformed(_))));
        assert!(matches!(
            decode(r#"{"type":"started","session":"s"}"#),
            Err(DecodeError::Malformed(_))
        ));
        assert!(matches!(
            decode(r#"{"v":1,"type":"mystery"}"#),
            Err(DecodeError::Malformed(_))
        ));
    }
}
