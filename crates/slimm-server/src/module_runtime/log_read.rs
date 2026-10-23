// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `log.read` (decision 0091): a cursor over a durable log the host keeps, so
//! code that must not lose data can catch up after it was not running. Phase 1
//! has one log, `voice.sessions`, which holds only closed sessions.
//!
//! Every path fails closed with a clean `{ok:false,error}`. The call spends the
//! run's shared host-call budget in the dispatcher, so it has none of its own.

use serde::Deserialize;
use serde_json::{Value, json};

/// Most rows one read returns.
pub const MAX_ROWS: i64 = 200;
/// Rows a read returns when it names no limit.
const DEFAULT_ROWS: i64 = 100;

/// One closed voice session as a module sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceSessionRow {
    pub id: i64,
    pub user_id: String,
    pub channel_id: String,
    pub joined_at_ms: i64,
    pub left_at_ms: i64,
    pub alone_ms: i64,
}

/// Where the logs live; a trait seam like [`super::KvBackend`].
pub trait LogBackend: Send + Sync {
    /// Closed sessions with an id above `after`, in id order, at most `limit`.
    fn voice_sessions(&self, after: i64, limit: i64) -> Result<Vec<VoiceSessionRow>, LogError>;
}

/// The backing store failed; the module sees a refusal, never the cause.
#[derive(Debug)]
pub struct LogError;

#[derive(Deserialize)]
struct LogRequest {
    log: Option<String>,
    #[serde(default)]
    after: Option<i64>,
    #[serde(default)]
    limit: Option<i64>,
}

/// Answers one `log.read` request against `backend`.
pub fn handle(backend: &dyn LogBackend, request: &[u8]) -> Vec<u8> {
    let Ok(req) = serde_json::from_slice::<LogRequest>(request) else {
        return refusal("malformed log.read request");
    };
    match req.log.as_deref() {
        Some("voice.sessions") => {}
        Some(other) => return refusal(&format!("unknown log: {other}")),
        None => return refusal("log.read needs a log"),
    }
    let after = req.after.unwrap_or(0).max(0);
    let limit = req.limit.unwrap_or(DEFAULT_ROWS).clamp(1, MAX_ROWS);
    match backend.voice_sessions(after, limit) {
        Ok(rows) => reply(after, &rows),
        Err(LogError) => refusal("log.read is unavailable"),
    }
}

fn reply(after: i64, rows: &[VoiceSessionRow]) -> Vec<u8> {
    let next = rows.last().map_or(after, |row| row.id);
    let rows: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.id,
                "user_id": r.user_id,
                "channel_id": r.channel_id,
                "joined_at_ms": r.joined_at_ms,
                "left_at_ms": r.left_at_ms,
                "alone_ms": r.alone_ms,
            })
        })
        .collect();
    serde_json::to_vec(&json!({ "ok": true, "rows": rows, "next": next }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

fn refusal(message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "ok": false, "error": message }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Default)]
    struct Recording(Mutex<Vec<(i64, i64)>>);

    impl LogBackend for Recording {
        fn voice_sessions(&self, after: i64, limit: i64) -> Result<Vec<VoiceSessionRow>, LogError> {
            self.0.lock().unwrap().push((after, limit));
            Ok(Vec::new())
        }
    }

    fn asked(request: &str) -> (i64, i64) {
        let backend = Recording::default();
        let reply = handle(&backend, request.as_bytes());
        assert!(String::from_utf8(reply).unwrap().contains(r#""ok":true"#));
        backend.0.lock().unwrap()[0]
    }

    #[test]
    fn a_huge_limit_is_capped() {
        let (_, limit) = asked(r#"{"log":"voice.sessions","limit":100000}"#);
        assert_eq!(limit, MAX_ROWS);
    }

    #[test]
    fn a_missing_limit_and_cursor_take_defaults_and_a_bad_one_is_clamped() {
        assert_eq!(asked(r#"{"log":"voice.sessions"}"#), (0, DEFAULT_ROWS));
        assert_eq!(
            asked(r#"{"log":"voice.sessions","after":-5,"limit":0}"#),
            (0, 1)
        );
    }
}
