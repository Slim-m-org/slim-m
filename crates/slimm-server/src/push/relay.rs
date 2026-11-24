// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The HTTP call to the push relay's batch send endpoint, and its wire types.
//!
//! The relay is a separate stateless Go service; this is a thin client for its
//! one endpoint. Everything it carries is already sealed by [`super::envelope`],
//! so nothing here ever sees plaintext content, and nothing here logs a token.

use std::borrow::Borrow;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::envelope::SealedMessage;

/// Bounded so one slow relay round trip cannot hang the delivery task
/// indefinitely. The message this notifies about is already committed and its
/// HTTP response already sent, so nothing but this background task is waiting.
/// The relay's own send deadline (8 seconds by default) must end before this does.
pub(super) const RELAY_TIMEOUT: Duration = Duration::from_secs(10);

/// Messages per request. The relay refuses more than 500 or a body over 1 MiB, and a sealed
/// payload can reach ~4 KB, so 100 stays under both limits.
pub(super) const MAX_BATCH: usize = 100;

#[derive(Serialize)]
struct SendRequest<'a> {
    messages: Vec<RelayMessage<'a>>,
}

/// Deliberately not `Debug`: `token` and `payload` are exactly what must never
/// be logged.
#[derive(Serialize)]
struct RelayMessage<'a> {
    platform: &'a str,
    token: &'a str,
    kind: &'a str,
    payload: &'a str,
}

#[derive(Deserialize)]
struct SendResponse {
    results: Vec<RelayResult>,
}

/// One token's outcome. Deliberately not `Debug`, so a token cannot end up in
/// a log line by accident.
#[derive(Deserialize)]
pub(super) struct RelayResult {
    pub(super) token: String,
    pub(super) status: String,
}

/// The relay's own per-token status vocabulary (slim-m-relay's
/// `internal/push.Status`), pinned here as the same seven literal wire
/// strings the cross-repo contract test pins on the Go side (see
/// `push_relay_contract_test.go`'s `contractCases`). `RelayResult::status`
/// above stays a bare `String` because the wire body carries no guarantee it
/// only ever holds one of these; parsing it into this enum explicitly, once,
/// rather than matching the raw string ad hoc at each call site, means a
/// status either side renames, drops, or grows without telling the other is
/// noticed here - as "not one of these" - instead of silently falling
/// through to "do nothing" alongside every genuinely inactionable status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RelayStatus {
    Delivered,
    Unregistered,
    Forbidden,
    /// Refused for good: resending the same message cannot succeed.
    Rejected,
    /// Not delivered now; a later attempt may succeed.
    Retry,
    /// Only a relay that predates `Rejected` and `Retry` sends this, so it may not know the kind.
    Error,
    NotAttempted,
}

impl RelayResult {
    /// Parses [`Self::status`] against the relay's documented vocabulary.
    /// `None` for anything else, including a status this server used to
    /// recognize but no longer does - the caller must treat that the same as
    /// any other status it takes no special action on, not crash or
    /// misroute, but it is worth a log line since it means the two repos
    /// have drifted.
    pub(super) fn parsed_status(&self) -> Option<RelayStatus> {
        match self.status.as_str() {
            "delivered" => Some(RelayStatus::Delivered),
            "unregistered" => Some(RelayStatus::Unregistered),
            "forbidden" => Some(RelayStatus::Forbidden),
            "rejected" => Some(RelayStatus::Rejected),
            "retry" => Some(RelayStatus::Retry),
            "error" => Some(RelayStatus::Error),
            "not_attempted" => Some(RelayStatus::NotAttempted),
            _ => None,
        }
    }
}

/// The largest relay answer read for one chunk: a result is about a token and a status word,
/// so this is several times what [`MAX_BATCH`] results need.
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// Why one chunk got no answer, and whether asking again could help.
#[derive(Debug)]
pub(super) struct RelayFailure {
    /// A transport error, 429 or 5xx; a 4xx refusal or a malformed answer would only repeat.
    pub(super) retryable: bool,
    /// What a 429 or 503 asked for through `Retry-After` in whole seconds.
    pub(super) retry_after: Option<Duration>,
    reason: String,
}

impl RelayFailure {
    fn permanent(reason: impl Into<String>) -> Self {
        Self {
            retryable: false,
            retry_after: None,
            reason: reason.into(),
        }
    }

    fn transport(err: reqwest::Error) -> Self {
        Self {
            retryable: true,
            retry_after: None,
            reason: err.without_url().to_string(),
        }
    }
}

impl std::fmt::Display for RelayFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason)
    }
}

impl std::error::Error for RelayFailure {}

/// Posts `messages` to the relay's `/v1/send` in chunks of [`MAX_BATCH`] and returns the
/// per-token results. A rejected chunk loses only its own devices, which then have no result;
/// the call fails only when every chunk did. `messages` is expected non-empty; the caller
/// filters out targets with nothing sealed to send before calling this.
pub(super) async fn send<M: Borrow<SealedMessage>>(
    http: &reqwest::Client,
    send_url: &str,
    key: &str,
    messages: &[M],
) -> Result<Vec<RelayResult>, RelayFailure> {
    let mut results = Vec::with_capacity(messages.len());
    let mut first_error = None;
    let mut failed_chunks = 0usize;
    let chunks = messages.chunks(MAX_BATCH);
    let total_chunks = chunks.len();
    for chunk in chunks {
        match send_chunk(http, send_url, key, chunk).await {
            Ok(chunk_results) => results.extend(chunk_results),
            Err(err) => {
                failed_chunks += 1;
                first_error.get_or_insert(err);
            }
        }
    }
    if let Some(err) = first_error {
        if failed_chunks == total_chunks {
            return Err(err);
        }
        tracing::warn!(error = %err, failed_chunks, total_chunks, "push: relay rejected some chunks");
    }
    Ok(results)
}

async fn send_chunk<M: Borrow<SealedMessage>>(
    http: &reqwest::Client,
    send_url: &str,
    key: &str,
    messages: &[M],
) -> Result<Vec<RelayResult>, RelayFailure> {
    let body = SendRequest {
        messages: messages
            .iter()
            .map(|m| {
                let m = m.borrow();
                RelayMessage {
                    platform: &m.platform,
                    token: &m.token,
                    kind: m.kind,
                    payload: &m.payload,
                }
            })
            .collect(),
    };
    let mut response = http
        .post(send_url)
        .bearer_auth(key)
        .json(&body)
        .send()
        .await
        .map_err(RelayFailure::transport)?;
    let status = response.status();
    if !status.is_success() {
        return Err(RelayFailure {
            retryable: status.as_u16() == 429 || status.is_server_error(),
            retry_after: retry_after(&response),
            reason: format!("relay answered {status}"),
        });
    }
    let bytes = read_capped(&mut response).await?;
    let parsed: SendResponse = serde_json::from_slice(&bytes).map_err(|err| {
        RelayFailure::permanent(format!("relay answer was not understood: {err}"))
    })?;
    Ok(parsed.results.into_iter().take(messages.len()).collect())
}

fn retry_after(response: &reqwest::Response) -> Option<Duration> {
    let seconds = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()?;
    Some(Duration::from_secs(seconds))
}

async fn read_capped(response: &mut reqwest::Response) -> Result<Vec<u8>, RelayFailure> {
    let too_large = || RelayFailure::permanent("relay answer was larger than this server reads");
    if response
        .content_length()
        .is_some_and(|len| len > MAX_RESPONSE_BYTES as u64)
    {
        return Err(too_large());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(RelayFailure::transport)? {
        if bytes.len() + chunk.len() > MAX_RESPONSE_BYTES {
            return Err(too_large());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[cfg(test)]
mod chunking_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the relay's per-result status vocabulary as literal wire
    /// strings on the server side, matching the literals
    /// `push_relay_contract_test.go`'s `contractCases` pins on the relay
    /// side. A status renamed, dropped, or added on one side without the
    /// other must show up as a test failure on at least one side; this is
    /// this side's half.
    #[test]
    fn parsed_status_accepts_exactly_the_documented_vocabulary_and_rejects_unknown() {
        let cases = [
            ("delivered", Some(RelayStatus::Delivered)),
            ("unregistered", Some(RelayStatus::Unregistered)),
            ("forbidden", Some(RelayStatus::Forbidden)),
            ("rejected", Some(RelayStatus::Rejected)),
            ("retry", Some(RelayStatus::Retry)),
            ("error", Some(RelayStatus::Error)),
            ("not_attempted", Some(RelayStatus::NotAttempted)),
            ("bogus", None),
            ("", None),
            ("Delivered", None), // case must matter: not a loose match
        ];
        for (wire, want) in cases {
            let result = RelayResult {
                token: "t".to_owned(),
                status: wire.to_owned(),
            };
            assert_eq!(result.parsed_status(), want, "status {wire:?}");
        }
    }

    /// Pins slim-m-relay's `config.DefaultSendTimeoutSeconds`, which that repo pins too.
    #[test]
    fn the_timeout_outlasts_the_relays_default_send_deadline() {
        const RELAY_DEFAULT_SEND_DEADLINE: Duration = Duration::from_secs(8);
        assert!(RELAY_TIMEOUT > RELAY_DEFAULT_SEND_DEADLINE);
    }
}
