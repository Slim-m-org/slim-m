// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Helpers beside the [`Event`] enum, kept out of `event.rs` for its size budget.

use super::event::Event;
use crate::ids::UserId;

/// Each emoji with who reacted and when, as `ReactionsChanged` carries it.
pub type Reactors = Vec<(String, Vec<(UserId, i64)>)>;

/// The one reactor a `ReactionsChanged` is about: who, on which emoji, and which way.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReactionMoved {
    pub emoji: String,
    pub user_id: UserId,
    pub added: bool,
}

impl Event {
    /// `user_id`'s presence moved; every connection resolves what its own user may be told.
    pub fn presence_changed(user_id: UserId) -> Event {
        Event::PresenceChanged(super::PresenceChange::of(user_id))
    }

    /// The event without any moderation stamp.
    pub fn into_inner(self) -> Event {
        match self {
            Event::Stamped { event, .. } => *event,
            other => other,
        }
    }
}
