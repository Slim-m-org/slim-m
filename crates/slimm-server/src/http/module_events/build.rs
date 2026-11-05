// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turning a hub event into the module events it stands for, and minting
//! their ids; an id is minted once per delivered event.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use super::wire::{EventData, PollOptionCount};
use crate::hub::{Event, MessageEvent};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::presence::Visibility;
use crate::store::Store;

/// Messages whose last reactors are remembered, to tell who reacted or took it back.
const TALLY_MEMORY: usize = 2048;

/// Which module event a hub event is, and the channel it happened in.
pub(super) struct Kind {
    pub(super) name: &'static str,
    pub(super) channel: Option<ChannelId>,
}

pub(super) fn classify(event: &Event) -> Option<Kind> {
    let (name, channel) = match event {
        Event::Message(MessageEvent::Created { message, .. }) => {
            ("message.created", Some(message.channel_id))
        }
        Event::Message(MessageEvent::Deleted { channel_id, .. }) => {
            ("message.deleted", Some(*channel_id))
        }
        Event::Message(MessageEvent::ReactionsChanged { channel_id, .. }) => {
            ("reaction.changed", Some(*channel_id))
        }
        Event::Message(MessageEvent::Edited { message, .. }) => {
            ("message.edited", Some(message.channel_id))
        }
        Event::Message(MessageEvent::PollVoted { channel_id, .. }) => {
            ("poll.voted", Some(*channel_id))
        }
        Event::VoiceParticipantJoined { channel_id, .. } => {
            ("voice.participant.joined", Some(*channel_id))
        }
        Event::VoiceParticipantLeft { channel_id, .. } => {
            ("voice.participant.left", Some(*channel_id))
        }
        Event::VoiceScreenShareChanged { channel_id, .. } => {
            ("voice.screen_share.changed", Some(*channel_id))
        }
        Event::MemberRoleChanged { .. } => ("member.roles.changed", None),
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
    /// Whose act this is, for a receiver that blocked them to be spared it.
    pub(super) actor: Option<UserId>,
    pub(super) data: EventData,
}

/// One reactor's move on one emoji, with the emoji's count afterwards.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct ReactionMove {
    emoji: String,
    user: UserId,
    added: bool,
    count: i64,
}

type Reactors = HashMap<String, HashSet<UserId>>;

/// Each message's last seen reactors, so a changed tally yields only who moved.
#[derive(Default)]
pub(super) struct ReactionTally(Mutex<HashMap<MessageId, Reactors>>);

impl ReactionTally {
    /// Every reactor who appeared or vanished since the last tally, with the emoji's new count.
    fn changes(&self, message: MessageId, now: Reactors) -> Vec<ReactionMove> {
        let mut seen = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if seen.len() >= TALLY_MEMORY {
            seen.clear();
        }
        let before = seen.insert(message, now.clone()).unwrap_or_default();
        let empty = HashSet::new();
        let mut moves = Vec::new();
        for emoji in now.keys().chain(before.keys()).collect::<HashSet<_>>() {
            let after = now.get(emoji).unwrap_or(&empty);
            let prior = before.get(emoji).unwrap_or(&empty);
            let count = i64::try_from(after.len()).unwrap_or(i64::MAX);
            let moved = after.difference(prior).map(|user| (user, true));
            let gone = prior.difference(after).map(|user| (user, false));
            moves.extend(moved.chain(gone).map(|(user, added)| ReactionMove {
                emoji: emoji.clone(),
                user: *user,
                added,
                count,
            }));
        }
        moves.sort();
        moves
    }
}

pub(super) async fn build(
    store: &Store,
    event: &Event,
    tally: &ReactionTally,
    now_ms: i64,
) -> anyhow::Result<Vec<Built>> {
    Ok(match event {
        Event::Message(MessageEvent::Created { message, .. }) => {
            let is_bot = match message.author_id {
                Some(author) => store.user_profile(author).await?.is_some_and(|u| u.is_bot),
                None => false,
            };
            vec![Built {
                id: format!("message:{}", message.id),
                created: Some((message.id, message.author_id)),
                at_ms: message.created_at,
                actor: None,
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
        Event::Message(MessageEvent::Deleted {
            channel_id,
            message_id,
            ..
        }) => vec![Built {
            id: format!("message-deleted:{message_id}"),
            created: None,
            at_ms: now_ms,
            actor: None,
            data: EventData::MessageDeleted {
                message_id: message_id.to_string(),
                channel_id: channel_id.to_string(),
            },
        }],
        Event::Message(MessageEvent::ReactionsChanged {
            channel_id,
            message_id,
            reactors,
        }) => {
            let now = reactors
                .iter()
                .map(|(emoji, who)| (emoji.clone(), who.iter().map(|(id, _)| *id).collect()))
                .collect();
            tally
                .changes(*message_id, now)
                .into_iter()
                .map(|m| Built {
                    id: format!("reaction:{message_id}:{}:{now_ms}:{}", m.emoji, m.user),
                    created: None,
                    at_ms: now_ms,
                    actor: Some(m.user),
                    data: EventData::ReactionChanged {
                        message_id: message_id.to_string(),
                        channel_id: channel_id.to_string(),
                        emoji: m.emoji,
                        count: m.count,
                        user_id: m.user.to_string(),
                        added: m.added,
                    },
                })
                .collect()
        }
        Event::Message(MessageEvent::Edited {
            message, op_seq, ..
        }) => {
            let is_bot = match message.author_id {
                Some(author) => store.user_profile(author).await?.is_some_and(|u| u.is_bot),
                None => false,
            };
            vec![Built {
                id: format!("message-edit:{}:{op_seq}", message.id),
                created: Some((message.id, message.author_id)),
                at_ms: message.edited_at.unwrap_or(now_ms),
                actor: None,
                data: EventData::MessageEdited {
                    message_id: message.id.to_string(),
                    channel_id: message.channel_id.to_string(),
                    author_id: message.author_id.map(|id| id.to_string()),
                    content: message.content.clone(),
                    edited_at_ms: message.edited_at.unwrap_or(now_ms),
                    is_bot,
                },
            }]
        }
        Event::Message(MessageEvent::PollVoted {
            channel_id,
            message_id,
            options,
            runoff,
        }) => vec![Built {
            id: format!("poll-vote:{message_id}:{now_ms}"),
            created: None,
            at_ms: now_ms,
            actor: None,
            data: EventData::PollVoted {
                message_id: message_id.to_string(),
                channel_id: channel_id.to_string(),
                options: options
                    .iter()
                    .map(|&(position, votes)| PollOptionCount { position, votes })
                    .collect(),
                ranked: runoff.is_some(),
                winner: runoff.as_ref().and_then(|r| r.winner),
            },
        }],
        Event::VoiceParticipantJoined {
            channel_id,
            user_id,
        } => {
            voice_event(store, *user_id, "voice-join", now_ms, || {
                EventData::VoiceParticipant {
                    channel_id: channel_id.to_string(),
                    user_id: user_id.to_string(),
                }
            })
            .await?
        }
        Event::VoiceParticipantLeft {
            channel_id,
            user_id,
        } => {
            voice_event(store, *user_id, "voice-leave", now_ms, || {
                EventData::VoiceParticipant {
                    channel_id: channel_id.to_string(),
                    user_id: user_id.to_string(),
                }
            })
            .await?
        }
        Event::VoiceScreenShareChanged {
            channel_id,
            user_id,
            is_sharing_screen,
        } => {
            voice_event(store, *user_id, "voice-share", now_ms, || {
                EventData::VoiceScreenShare {
                    channel_id: channel_id.to_string(),
                    user_id: user_id.to_string(),
                    sharing: *is_sharing_screen,
                }
            })
            .await?
        }
        Event::MemberRoleChanged {
            user_id,
            role_id,
            granted,
            role_name,
        } => vec![Built {
            id: format!("member-roles:{user_id}:{role_id}:{now_ms}"),
            created: None,
            at_ms: now_ms,
            actor: None,
            data: EventData::MemberRoles {
                user_id: user_id.to_string(),
                role_id: role_id.to_string(),
                granted: *granted,
                role_name: role_name.clone(),
            },
        }],
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
            actor: None,
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

/// A voice event for `user`, held back when they chose to appear hidden, as the live frames do (decision 0032).
async fn voice_event(
    store: &Store,
    user: UserId,
    prefix: &str,
    now_ms: i64,
    data: impl FnOnce() -> EventData,
) -> anyhow::Result<Vec<Built>> {
    if store.presence_visibility(user).await? == Some(Visibility::Hidden) {
        return Ok(Vec::new());
    }
    Ok(vec![Built {
        id: format!("{prefix}:{user}:{now_ms}"),
        created: None,
        at_ms: now_ms,
        actor: None,
        data: data(),
    }])
}

fn member(prefix: &str, user: UserId, now_ms: i64) -> Built {
    Built {
        id: format!("{prefix}:{user}:{now_ms}"),
        created: None,
        at_ms: now_ms,
        actor: None,
        data: EventData::Member {
            user_id: user.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn who(pairs: &[(&str, &[UserId])]) -> Reactors {
        pairs
            .iter()
            .map(|(e, users)| ((*e).to_owned(), users.iter().copied().collect()))
            .collect()
    }

    fn mv(emoji: &str, user: UserId, added: bool, count: i64) -> ReactionMove {
        ReactionMove {
            emoji: emoji.to_owned(),
            user,
            added,
            count,
        }
    }

    #[test]
    fn a_tally_names_who_reacted_or_took_it_back_with_the_new_count() {
        let tally = ReactionTally::default();
        let message = MessageId::generate();
        let (ann, bob) = (UserId::generate(), UserId::generate());
        let first = tally.changes(message, who(&[("a", &[ann])]));
        assert_eq!(first, vec![mv("a", ann, true, 1)]);
        let second = tally.changes(message, who(&[("a", &[ann]), ("b", &[bob])]));
        assert_eq!(second, vec![mv("b", bob, true, 1)]);
        let third = tally.changes(message, who(&[("a", &[ann, bob]), ("b", &[bob])]));
        assert_eq!(third, vec![mv("a", bob, true, 2)]);
        let fourth = tally.changes(message, who(&[("a", &[ann]), ("b", &[bob])]));
        assert_eq!(fourth, vec![mv("a", bob, false, 1)]);
        let fifth = tally.changes(message, who(&[("b", &[bob])]));
        assert_eq!(fifth, vec![mv("a", ann, false, 0)]);
    }
}
