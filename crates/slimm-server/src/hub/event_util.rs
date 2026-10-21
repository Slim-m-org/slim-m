// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Helpers beside the [`Event`] enum, kept out of `event.rs` for its size budget.

use super::event::Event;
use crate::ids::UserId;

/// Each emoji with who reacted and when, as `ReactionsChanged` carries it.
pub type Reactors = Vec<(String, Vec<(UserId, i64)>)>;

impl Event {
    /// The event without any moderation stamp.
    pub fn into_inner(self) -> Event {
        match self {
            Event::Stamped { event, .. } => *event,
            other => other,
        }
    }
}
