// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `listener/1` messages, this side. The server has its own copy of the
//! types; both parse the fixtures in `protocol/` so they cannot drift apart.

use serde::{Deserialize, Serialize};

/// The protocol version spoken here.
pub const VERSION: u64 = 1;

/// What the server sends.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
/// Tagged by `type`.
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    Start {
        session: String,
        livekit_url: String,
        token: String,
        include: Vec<String>,
        language: Option<String>,
    },
    /// The whole set, not a delta.
    Include {
        session: String,
        include: Vec<String>,
    },
    Stop {
        session: String,
    },
}

/// What this side sends.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
/// Tagged by `type`.
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Report {
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

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// A newer protocol version: close the connection.
    Newer(u64),
    Malformed(String),
}

/// `report` as a frame carrying `"v": 1`.
pub fn encode(report: &Report) -> String {
    let mut value = serde_json::to_value(report).unwrap_or_default();
    if let Some(object) = value.as_object_mut() {
        object.insert("v".into(), VERSION.into());
    }
    value.to_string()
}

/// Parses one frame from the server.
pub fn decode(text: &str) -> Result<Command, DecodeError> {
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

    fn fixture(name: &str) -> String {
        let path = format!("{}/protocol/{name}.json", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(path).expect("fixture exists")
    }

    #[test]
    fn every_server_fixture_parses() {
        for name in ["start", "include", "stop"] {
            decode(&fixture(name)).unwrap_or_else(|e| panic!("{name}: {e:?}"));
        }
    }

    #[test]
    fn every_report_matches_its_fixture() {
        let cases = [
            (
                "ready",
                Report::Ready {
                    version: "0.1.0".into(),
                    engine: "whisper.cpp".into(),
                    model: "ggml-base.bin".into(),
                    max_sessions: 2,
                },
            ),
            (
                "started",
                Report::Started {
                    session: "s1".into(),
                },
            ),
            (
                "segment",
                Report::Segment {
                    session: "s1".into(),
                    identity: "u1".into(),
                    start_ms: 1200,
                    end_ms: 3400,
                    text: "hello there".into(),
                    language: Some("en".into()),
                },
            ),
            (
                "ended",
                Report::Ended {
                    session: "s1".into(),
                    reason: "overload".into(),
                },
            ),
        ];
        for (name, report) in cases {
            let sent: serde_json::Value = serde_json::from_str(&encode(&report)).unwrap();
            let expected: serde_json::Value = serde_json::from_str(&fixture(name)).unwrap();
            assert_eq!(sent, expected, "{name}");
        }
    }

    #[test]
    fn a_newer_version_is_told_apart_from_garbage() {
        assert_eq!(
            decode(r#"{"v":2,"type":"stop","session":"s"}"#),
            Err(DecodeError::Newer(2))
        );
        assert!(matches!(decode("nope"), Err(DecodeError::Malformed(_))));
        assert!(matches!(
            decode(r#"{"type":"stop","session":"s"}"#),
            Err(DecodeError::Malformed(_))
        ));
    }
}
