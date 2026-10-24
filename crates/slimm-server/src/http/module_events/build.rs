// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turning a hub event into the module events it stands for, and minting
//! their ids; an id is minted once per delivered event.

use std::collections::HashMap;
use std::sync::Mutex;

use super::wire::EventData;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::Store;

/// Messages whose last reaction tally is remembered, to tell which emoji moved.
const TALLY_MEMORY: usize = 2048;

/// Which module event a hub event is, and the channel it happened in.
pub(super) struct Kind {
    pub(super) name: &'static str,
    pub(super) channel: Option<ChannelId>,
}

pub(super) fn classify(event: &Event) -> Option<Kind> {
    let (name, channel) = match event {
        Event::MessageCreated { message, .. } => ("message.created", Some(message.channel_id)),
        Event::MessageDeleted { channel_id, .. } => ("message.deleted", Some(*channel_id)),
        Event::ReactionsChanged { channel_id, .. } => ("reaction.changed", Some(*channel_id)),
        Event::MemberJoined(_) => ("member.joined", None),
        Event::MemberRemoved(_) => ("member.left", None),
        Event::VoiceSessionClosed { channel_id, .. } => ("voice.session.closed", Some(*channel_id)),
        _ => return None,
    };
    Some(Kind { name, channel })
}

/// One module event, ready to render.
pub(super) struct Built {
    pub(super) id: String,
    /// The message and its author when this is a `message.created`.
    pub(super) created: Option<(MessageId, Option<UserId>)>,
    pub(super) at_ms: i64,
    pub(super) data: EventData,
}

/// Each message's last seen reaction counts, so a changed tally yields only the emoji that moved.
#[derive(Default)]
pub(super) struct ReactionTally(Mutex<HashMap<MessageId, HashMap<String, i64>>>);

impl ReactionTally {
    /// `(emoji, count)` for every emoji whose count differs from the last tally; a removed one reads 0.
    fn changes(&self, message: MessageId, now: HashMap<String, i64>) -> Vec<(String, i64)> {
        let mut seen = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if seen.len() >= TALLY_MEMORY {
            seen.clear();
        }
        let before = seen.insert(message, now.clone()).unwrap_or_default();
        let mut changed: Vec<(String, i64)> = now
            .iter()
            .filter(|(emoji, count)| before.get(*emoji) != Some(count))
            .map(|(emoji, count)| (emoji.clone(), *count))
            .collect();
        changed.extend(
            before
                .keys()
                .filter(|emoji| !now.contains_key(*emoji))
                .map(|emoji| (emoji.clone(), 0)),
        );
        changed.sort();
        changed
    }
}

pub(super) async fn build(
    store: &Store,
    event: &Event,
    tally: &ReactionTally,
    now_ms: i64,
) -> anyhow::Result<Vec<Built>> {
    Ok(match event {
        Event::MessageCreated { message, .. } => {
            let is_bot = match message.author_id {
                Some(author) => store.user_profile(author).await?.is_some_and(|u| u.is_bot),
                None => false,
            };
            vec![Built {
                id: format!("message:{}", message.id),
                created: Some((message.id, message.author_id)),
                at_ms: message.created_at,
                data: EventData::MessageCreated {
                    message_id: message.id.to_string(),
                    channel_id: message.channel_id.to_string(),
                    author_id: message.author_id.map(|id| id.to_string()),
                    content: message.content.clone(),
                    created_at_ms: message.created_at,
                    is_bot,
                },
            }]
        }
        Event::MessageDeleted {
            channel_id,
            message_id,
            ..
        } => vec![Built {
            id: format!("message-deleted:{message_id}"),
            created: None,
            at_ms: now_ms,
            data: EventData::MessageDeleted {
                message_id: message_id.to_string(),
                channel_id: channel_id.to_string(),
            },
        }],
        Event::ReactionsChanged {
            channel_id,
            message_id,
            reactors,
        } => {
            let counts = reactors
                .iter()
                .map(|(emoji, who)| (emoji.clone(), i64::try_from(who.len()).unwrap_or(i64::MAX)))
                .collect();
            tally
                .changes(*message_id, counts)
                .into_iter()
                .map(|(emoji, count)| Built {
                    id: format!("reaction:{message_id}:{emoji}:{now_ms}"),
                    created: None,
                    at_ms: now_ms,
                    data: EventData::ReactionChanged {
                        message_id: message_id.to_string(),
                        channel_id: channel_id.to_string(),
                        emoji,
                        count,
                    },
                })
                .collect()
        }
        Event::MemberJoined(user) => vec![member("member-join", *user, now_ms)],
        Event::MemberRemoved(user) => vec![member("member-leave", *user, now_ms)],
        Event::VoiceSessionClosed {
            session_id,
            user_id,
            channel_id,
            joined_at_ms,
            left_at_ms,
            alone_ms,
        } => vec![Built {
            id: format!("voice-session:{session_id}"),
            created: None,
            at_ms: *left_at_ms,
            data: EventData::VoiceSessionClosed {
                session_id: *session_id,
                user_id: user_id.to_string(),
                channel_id: channel_id.to_string(),
                joined_at_ms: *joined_at_ms,
                left_at_ms: *left_at_ms,
                alone_ms: *alone_ms,
            },
        }],
        _ => Vec::new(),
    })
}

fn member(prefix: &str, user: UserId, now_ms: i64) -> Built {
    Built {
        id: format!("{prefix}:{user}:{now_ms}"),
        created: None,
        at_ms: now_ms,
        data: EventData::Member {
            user_id: user.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts(pairs: &[(&str, i64)]) -> HashMap<String, i64> {
        pairs.iter().map(|(e, c)| ((*e).to_owned(), *c)).collect()
    }

    #[test]
    fn a_tally_reports_only_the_emoji_that_moved_and_removals_as_zero() {
        let tally = ReactionTally::default();
        let message = MessageId::generate();
        let first = tally.changes(message, counts(&[("a", 1)]));
        assert_eq!(first, vec![("a".to_owned(), 1)]);
        let second = tally.changes(message, counts(&[("a", 1), ("b", 1)]));
        assert_eq!(second, vec![("b".to_owned(), 1)]);
        let third = tally.changes(message, counts(&[("b", 1)]));
        assert_eq!(third, vec![("a".to_owned(), 0)]);
    }
}
