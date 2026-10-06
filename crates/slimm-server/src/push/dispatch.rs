// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Sending a sealed batch and acting on what the relay reports back.

use std::collections::HashSet;

use super::Enabled;
use super::envelope::SealedMessage;
use super::relay::{self, RelayResult, RelayStatus};
use super::sealing::TokenSlot;
use crate::ids::UserId;
use crate::store::Store;

/// What the relay said about a batch, resolved from its bare echoed tokens back to this
/// batch's devices.
#[derive(Default)]
pub(super) struct Triage<'a> {
    /// Users with at least one device the relay reports as `Delivered`.
    pub(super) delivered: HashSet<UserId>,
    /// Devices whose token the relay reports dead.
    pub(super) dead: Vec<&'a SealedMessage>,
    /// How many results carried a status this server does not recognize.
    pub(super) unrecognized: usize,
}

impl<'a> Triage<'a> {
    pub(super) fn of(messages: &'a [SealedMessage], results: &[RelayResult]) -> Self {
        let mut triage = Self::default();
        for result in results {
            let Some(message) = messages.iter().find(|m| m.token == result.token) else {
                continue;
            };
            match result.parsed_status() {
                Some(RelayStatus::Delivered) => {
                    triage.delivered.insert(message.user_id);
                }
                Some(RelayStatus::Unregistered) => triage.dead.push(message),
                Some(RelayStatus::Forbidden | RelayStatus::Error | RelayStatus::NotAttempted) => {}
                None => triage.unrecognized += 1,
            }
        }
        triage
    }
}

/// Sends `messages`, prunes every token the relay reports dead and warns on a status it does
/// not recognize. Returns the users the relay delivered to, or `None` when it was unreachable.
pub(super) async fn send_and_prune(
    enabled: &Enabled,
    store: &Store,
    messages: &[SealedMessage],
    what: &'static str,
) -> Option<HashSet<UserId>> {
    if messages.is_empty() {
        return Some(HashSet::new());
    }
    let results = match relay::send(&enabled.http, &enabled.send_url, &enabled.key, messages).await
    {
        Ok(results) => results,
        Err(err) => {
            tracing::warn!(error = %err, what, "push: relay send failed");
            return None;
        }
    };
    let triage = Triage::of(messages, &results);
    for message in &triage.dead {
        clear_dead(store, message).await;
    }
    if triage.unrecognized > 0 {
        tracing::warn!(
            count = triage.unrecognized,
            what,
            "push: relay reported a status this server does not recognize"
        );
    }
    Some(triage.delivered)
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
        let messages = [sealed("a"), sealed("b"), sealed("c"), sealed("d")];
        let results = [
            result("a", "delivered"),
            result("b", "unregistered"),
            result("c", "brand_new_status"),
            result("d", "error"),
            result("not-in-this-batch", "delivered"),
        ];
        let triage = Triage::of(&messages, &results);
        assert_eq!(triage.delivered, HashSet::from([messages[0].user_id]));
        assert_eq!(triage.dead.len(), 1);
        assert_eq!(triage.dead[0].token, "b");
        assert_eq!(triage.unrecognized, 1);
    }
}
