// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Sending a sealed batch and acting on what the relay reports back.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use super::Enabled;
use super::envelope::{PushKind, SealedMessage};
use super::relay::{self, RelayResult, RelayStatus};
use super::sealing::TokenSlot;
use crate::ids::UserId;
use crate::store::{Store, now_ms};

/// What the relay said about a batch, resolved from its bare echoed tokens back to this
/// batch's devices.
#[derive(Default)]
pub(super) struct Triage<'a> {
    /// Users with at least one device the relay reports as `Delivered`.
    pub(super) delivered: HashSet<UserId>,
    /// Devices whose token the relay reports dead.
    pub(super) dead: Vec<&'a SealedMessage>,
    /// How many results the relay refused as `forbidden`.
    pub(super) forbidden: usize,
    /// How many results the relay refused for good as `rejected`.
    pub(super) rejected: usize,
    /// How many results the relay could not deliver right now and answered `retry`.
    pub(super) retry: usize,
    /// How many results carried a status this server does not recognize.
    pub(super) unrecognized: usize,
    /// Messages a relay that predates `rejected` and `retry` answered `error` for.
    pub(super) refused: Vec<&'a SealedMessage>,
    /// Messages the relay did not attempt or asked to send again later.
    pub(super) resendable: Vec<&'a SealedMessage>,
}

impl<'a> Triage<'a> {
    pub(super) fn of(messages: &[&'a SealedMessage], results: &[RelayResult]) -> Self {
        let mut by_token: HashMap<&str, &'a SealedMessage> = HashMap::with_capacity(messages.len());
        for message in messages {
            by_token.entry(message.token.as_str()).or_insert(message);
        }
        let mut triage = Self::default();
        for result in results {
            let Some(&message) = by_token.get(result.token.as_str()) else {
                continue;
            };
            match result.parsed_status() {
                Some(RelayStatus::Delivered) => {
                    triage.delivered.insert(message.user_id);
                }
                Some(RelayStatus::Unregistered) => triage.dead.push(message),
                Some(RelayStatus::Forbidden) => triage.forbidden += 1,
                Some(RelayStatus::Rejected) => triage.rejected += 1,
                Some(RelayStatus::Retry) => {
                    triage.retry += 1;
                    triage.resendable.push(message);
                }
                Some(RelayStatus::Error) => triage.refused.push(message),
                Some(RelayStatus::NotAttempted) => triage.resendable.push(message),
                None => triage.unrecognized += 1,
            }
        }
        triage
    }
}

/// How long to keep sending the older kinds after a relay refused the newer ones.
const LEGACY_KINDS_FOR_MS: i64 = 60 * 60 * 1000;

/// The kind a relay older than `voice` and `admin_alert` knows in their place, or `None`.
fn legacy_kind(kind: &str) -> Option<&'static str> {
    match kind {
        "voice" => Some("message"),
        "admin_alert" => Some("security"),
        _ => None,
    }
}

fn with_legacy_kind(message: &SealedMessage) -> SealedMessage {
    SealedMessage {
        kind: legacy_kind(message.kind).unwrap_or(message.kind),
        ..message.clone()
    }
}

/// Sends `messages`, prunes every token the relay reports dead and warns on a status it does
/// not recognize. Returns the users the relay delivered to, or `None` when it was unreachable.
///
/// A relay that predates a kind answers `error` for it, so those are sent again under the kind
/// it knows, and for a while after the older kind got through where every new one was refused
/// they go out that way. A relay that knows `rejected` and `retry` never answers `error`.
pub(super) async fn send_and_prune(
    enabled: &Enabled,
    store: &Store,
    messages: &[SealedMessage],
    what: &'static str,
) -> Option<HashSet<UserId>> {
    if enabled.legacy_kinds_until.load(Ordering::Relaxed) > now_ms() {
        let legacy: Vec<_> = messages.iter().map(with_legacy_kind).collect();
        return send_once(enabled, store, &legacy, what)
            .await
            .map(|(d, _)| d);
    }
    let (mut delivered, refused) = send_once(enabled, store, messages, what).await?;
    let resend: Vec<_> = refused
        .iter()
        .filter(|m| legacy_kind(m.kind).is_some())
        .map(|m| with_legacy_kind(m))
        .collect();
    if resend.is_empty() {
        return Some(delivered);
    }
    let new_kinds = messages
        .iter()
        .filter(|m| legacy_kind(m.kind).is_some())
        .count();
    let older_kind_got_through = match send_once(enabled, store, &resend, what).await {
        Some((again, _)) => {
            let any = !again.is_empty();
            delivered.extend(again);
            any
        }
        None => false,
    };
    if older_kind_got_through && resend.len() == new_kinds {
        enabled
            .legacy_kinds_until
            .store(now_ms() + LEGACY_KINDS_FOR_MS, Ordering::Relaxed);
        tracing::info!(
            what,
            "push: the relay refused its newer kinds; sending the older ones for now"
        );
    }
    Some(delivered)
}

/// How many times a message the relay could not take is sent again.
const MAX_RESENDS: usize = 2;

/// The wait before the first resend; it doubles for the next one.
const RESEND_BACKOFF: Duration = Duration::from_millis(250);

/// The longest a resend waits, whatever the relay's `Retry-After` asked for.
const MAX_RESEND_WAIT: Duration = Duration::from_secs(5);

/// A ring is worthless once it has stopped ringing, so resends of one stop after this long.
const RING_RESEND_BUDGET: Duration = Duration::from_secs(10);

fn resend_wait(attempt: usize, retry_after: Option<Duration>) -> Duration {
    let backoff = RESEND_BACKOFF * 2u32.pow(attempt as u32);
    retry_after
        .unwrap_or_default()
        .max(backoff)
        .min(MAX_RESEND_WAIT)
}

fn is_ring(message: &SealedMessage) -> bool {
    message.kind == PushKind::Call.wire_str()
}

/// What one request round learned.
#[derive(Default)]
struct Round<'a> {
    delivered: HashSet<UserId>,
    refused: Vec<&'a SealedMessage>,
    resendable: Vec<&'a SealedMessage>,
    retry_after: Option<Duration>,
    reached: bool,
}

/// One send: the delivered users and the messages the relay answered `error` for. Messages the
/// relay could not take right now are sent again a couple of times; `None` when it never answered.
async fn send_once<'a>(
    enabled: &Enabled,
    store: &Store,
    messages: &'a [SealedMessage],
    what: &'static str,
) -> Option<(HashSet<UserId>, Vec<&'a SealedMessage>)> {
    if messages.is_empty() {
        return Some((HashSet::new(), Vec::new()));
    }
    let started = Instant::now();
    let mut pending: Vec<&SealedMessage> = messages.iter().collect();
    let mut delivered = HashSet::new();
    let mut refused = Vec::new();
    let mut reached = false;
    for attempt in 0..=MAX_RESENDS {
        pending.retain(|m| m.ring_id.is_none_or(|ring| !enabled.ring_ended(ring)));
        if pending.is_empty() {
            break;
        }
        let round = send_round(enabled, store, &pending, what).await;
        reached |= round.reached;
        delivered.extend(round.delivered);
        refused.extend(round.refused);
        pending = round.resendable;
        if pending.is_empty() {
            break;
        }
        if attempt == MAX_RESENDS {
            tracing::warn!(
                count = pending.len(),
                what,
                "push: gave up resending to the relay"
            );
            break;
        }
        let wait = resend_wait(attempt, round.retry_after);
        pending.retain(|m| !is_ring(m) || started.elapsed() + wait < RING_RESEND_BUDGET);
        if pending.is_empty() {
            break;
        }
        tokio::time::sleep(wait).await;
    }
    reached.then_some((delivered, refused))
}

async fn send_round<'a>(
    enabled: &Enabled,
    store: &Store,
    messages: &[&'a SealedMessage],
    what: &'static str,
) -> Round<'a> {
    let results = match relay::send(&enabled.http, &enabled.send_url, &enabled.key, messages).await
    {
        Ok(results) => results,
        Err(err) => {
            tracing::warn!(error = %err, what, "push: relay send failed");
            enabled.relay_failures.fetch_add(1, Ordering::Relaxed);
            return Round {
                resendable: if err.retryable {
                    messages.to_vec()
                } else {
                    Vec::new()
                },
                retry_after: err.retry_after,
                ..Round::default()
            };
        }
    };
    enabled.relay_failures.store(0, Ordering::Relaxed);
    let triage = Triage::of(messages, &results);
    for message in &triage.dead {
        clear_dead(store, message).await;
    }
    log_triage(enabled, &triage, what);
    let answered: HashSet<&str> = results.iter().map(|r| r.token.as_str()).collect();
    let mut resendable = triage.resendable;
    resendable.extend(
        messages
            .iter()
            .filter(|m| !answered.contains(m.token.as_str())),
    );
    Round {
        delivered: triage.delivered,
        refused: triage.refused,
        resendable,
        retry_after: None,
        reached: true,
    }
}

fn log_triage(enabled: &Enabled, triage: &Triage<'_>, what: &'static str) {
    if triage.forbidden > 0 {
        enabled
            .forbidden
            .fetch_add(triage.forbidden as u64, Ordering::Relaxed);
        tracing::warn!(
            count = triage.forbidden,
            what,
            "push: relay refused devices as forbidden; this server's key is not allowed to deliver to them"
        );
    }
    if triage.rejected > 0 || triage.retry > 0 {
        tracing::warn!(
            rejected = triage.rejected,
            retry = triage.retry,
            what,
            "push: relay could not deliver some devices"
        );
    }
    if triage.unrecognized > 0 {
        tracing::warn!(
            count = triage.unrecognized,
            what,
            "push: relay reported a status this server does not recognize"
        );
    }
}

/// Clears the one token the relay reported dead, never the device's other one.
pub(super) async fn clear_dead(store: &Store, message: &SealedMessage) {
    let cleared = match message.slot {
        TokenSlot::Push => {
            store
                .clear_push_registration(message.user_id, message.device_id, &message.token)
                .await
        }
        TokenSlot::Voip => {
            store
                .clear_voip_push_token(message.user_id, message.device_id, &message.token)
                .await
        }
    };
    if let Err(err) = cleared {
        tracing::warn!(error = %err, "push: failed to clear a dead registration");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::DeviceId;

    fn sealed(token: &str) -> SealedMessage {
        SealedMessage {
            user_id: UserId::generate(),
            device_id: DeviceId::generate(),
            platform: "android".to_owned(),
            token: token.to_owned(),
            slot: TokenSlot::Push,
            kind: "message",
            payload: String::new(),
            ring_id: None,
        }
    }

    fn result(token: &str, status: &str) -> RelayResult {
        RelayResult {
            token: token.to_owned(),
            status: status.to_owned(),
        }
    }

    #[test]
    fn triage_sorts_every_relay_status_for_every_push_path() {
        let messages = [
            sealed("a"),
            sealed("b"),
            sealed("c"),
            sealed("d"),
            sealed("e"),
            sealed("f"),
            sealed("g"),
        ];
        let results = [
            result("a", "delivered"),
            result("b", "unregistered"),
            result("c", "brand_new_status"),
            result("d", "error"),
            result("e", "forbidden"),
            result("f", "rejected"),
            result("g", "retry"),
            result("not-in-this-batch", "delivered"),
        ];
        let refs: Vec<&SealedMessage> = messages.iter().collect();
        let triage = Triage::of(&refs, &results);
        assert_eq!(triage.delivered, HashSet::from([messages[0].user_id]));
        assert_eq!(triage.dead.len(), 1);
        assert_eq!(triage.dead[0].token, "b");
        assert_eq!(triage.unrecognized, 1);
        assert_eq!(triage.forbidden, 1);
        assert_eq!(triage.rejected, 1);
        assert_eq!(triage.retry, 1);
        assert_eq!(triage.refused.len(), 1);
        assert_eq!(triage.refused[0].token, "d");
        assert_eq!(triage.resendable.len(), 1);
        assert_eq!(triage.resendable[0].token, "g");
    }
}
