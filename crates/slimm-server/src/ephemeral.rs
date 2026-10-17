// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message only one member can see, sent by a bot and never stored.
//! See docs/decisions/0037-ephemeral-bot-messages.md.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use crate::http::embeds::EmbedDto;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::AttachmentSummary;

/// How long after a member's message a bot may still answer it privately.
pub const ANCHOR_WINDOW_MS: i64 = 15 * 60 * 1000;

/// The most a channel keeps per recipient is a client concern; the server
/// holds nothing, so this is only the shape that crosses the hub.
#[derive(Debug, Clone)]
pub struct EphemeralMessage {
    pub id: MessageId,
    pub channel_id: ChannelId,
    pub author_id: UserId,
    pub author_display_name: String,
    pub content: String,
    pub in_reply_to_id: MessageId,
    pub created_at: i64,
    /// Files the recipient could already fetch; the message owns no bytes.
    pub attachments: Vec<AttachmentSummary>,
    pub(crate) embeds: Vec<EmbedDto>,
}

/// Most private messages one bot may send about one anchor.
pub const MAX_PER_ANCHOR: u32 = 3;

/// Above this many tracked anchors, expired ones are swept on the next charge.
const SWEEP_ABOVE: usize = 256;

/// Messages sent so far and the instant the anchor stops entitling more.
type Spent = (u32, i64);

/// How many private messages each (bot, anchor) has used, in memory only.
///
/// An entry lives until its anchor's window closes and is then forgotten, so
/// the map is bounded by the anchors still inside the window.
#[derive(Clone, Default)]
pub struct EphemeralBudget {
    used: Arc<Mutex<HashMap<(UserId, Uuid), Spent>>>,
}

impl EphemeralBudget {
    /// Spends one message of `bot`'s budget for `anchor`, or says it is spent.
    pub fn try_charge(&self, bot: UserId, anchor: Uuid, expires_at: i64, now: i64) -> bool {
        let mut used = self
            .used
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if used.len() > SWEEP_ABOVE {
            used.retain(|_, (_, expires)| *expires > now);
        }
        let entry = used.entry((bot, anchor)).or_insert((0, expires_at));
        if entry.1 <= now {
            *entry = (0, expires_at);
        }
        if entry.0 >= MAX_PER_ANCHOR {
            return false;
        }
        entry.0 += 1;
        true
    }
}

/// Whether `content` opens with `prefix` followed by one of `commands`, the
/// way a bot's own parser reads a command it registered.
pub fn invokes_command<'a>(
    content: &str,
    prefix: &str,
    commands: impl IntoIterator<Item = &'a str>,
) -> bool {
    let Some(rest) = content.strip_prefix(prefix) else {
        return false;
    };
    let Some(word) = rest.split_whitespace().next() else {
        return false;
    };
    commands
        .into_iter()
        .any(|name| name.eq_ignore_ascii_case(word))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_needs_the_prefix_and_a_registered_name() {
        let names = ["ping", "Roll"];
        assert!(invokes_command("!ping", "!", names));
        assert!(invokes_command("!roll 20", "!", names));
        assert!(!invokes_command("!pingpong", "!", names));
        assert!(!invokes_command("ping", "!", names));
        assert!(!invokes_command("!", "!", names));
        assert!(!invokes_command("!other", "!", names));
    }

    #[test]
    fn the_budget_runs_out_per_anchor_and_resets_after_expiry() {
        let budget = EphemeralBudget::default();
        let (bot, other) = (UserId::generate(), UserId::generate());
        let anchor = Uuid::now_v7();
        for _ in 0..MAX_PER_ANCHOR {
            assert!(budget.try_charge(bot, anchor, 100, 10));
        }
        assert!(!budget.try_charge(bot, anchor, 100, 10));
        assert!(budget.try_charge(other, anchor, 100, 10));
        assert!(budget.try_charge(bot, Uuid::now_v7(), 100, 10));
        assert!(budget.try_charge(bot, anchor, 300, 200));
    }
}
