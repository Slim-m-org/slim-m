// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Working a voice channel's calls out of its recorded events (decision
//! 0066): a call starts when the room goes from nobody to somebody and ends
//! when it is empty again.

use std::collections::HashSet;

use crate::ids::UserId;
use crate::store::{VoiceEvent, VoiceEventKind};

#[derive(Debug, Clone, PartialEq)]
pub struct Call {
    pub started_at: i64,
    /// None while someone LiveKit still reports is in it.
    pub ended_at: Option<i64>,
    /// Only the events that changed something, oldest first.
    pub events: Vec<VoiceEvent>,
}

/// The calls in `events` (oldest first), newest call first. `present` is
/// who LiveKit says is in the room now: a call still open at the end is
/// ongoing only if one of them is still in it, and otherwise ended at its
/// last event, which is what closes a call a missed leave left open.
pub fn segment(events: &[VoiceEvent], present: &HashSet<UserId>) -> Vec<Call> {
    let mut calls = Vec::new();
    let mut inside: HashSet<UserId> = HashSet::new();
    let mut sharing: HashSet<UserId> = HashSet::new();
    let mut current: Option<Call> = None;
    for event in events {
        let changed = match event.kind {
            VoiceEventKind::Joined => inside.insert(event.user_id),
            VoiceEventKind::Left => {
                sharing.remove(&event.user_id);
                inside.remove(&event.user_id)
            }
            VoiceEventKind::ShareStarted => {
                inside.contains(&event.user_id) && sharing.insert(event.user_id)
            }
            VoiceEventKind::ShareStopped => sharing.remove(&event.user_id),
        };
        if !changed {
            continue;
        }
        let call = current.get_or_insert_with(|| Call {
            started_at: event.at,
            ended_at: None,
            events: Vec::new(),
        });
        call.events.push(*event);
        if inside.is_empty() {
            let mut done = current.take().expect("a call was just filled");
            done.ended_at = Some(event.at);
            calls.push(done);
        }
    }
    if let Some(mut open) = current {
        if !inside.iter().any(|user| present.contains(user)) {
            open.ended_at = open.events.last().map(|e| e.at);
        }
        calls.push(open);
    }
    calls.reverse();
    calls
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn user(n: u128) -> UserId {
        UserId(Uuid::from_u128(n))
    }

    fn ev(at: i64, who: u128, kind: VoiceEventKind) -> VoiceEvent {
        VoiceEvent {
            at,
            user_id: user(who),
            kind,
        }
    }

    use VoiceEventKind::*;

    #[test]
    fn a_call_runs_from_the_first_join_to_the_last_leave() {
        let events = [
            ev(10, 1, Joined),
            ev(20, 2, Joined),
            ev(30, 1, Left),
            ev(40, 2, Left),
            ev(100, 1, Joined),
            ev(110, 1, Left),
        ];
        let calls = segment(&events, &HashSet::new());
        assert_eq!(calls.len(), 2);
        assert_eq!((calls[0].started_at, calls[0].ended_at), (100, Some(110)));
        assert_eq!((calls[1].started_at, calls[1].ended_at), (10, Some(40)));
        assert_eq!(calls[1].events.len(), 4);
    }

    #[test]
    fn duplicates_and_strays_change_nothing() {
        let events = [
            ev(5, 3, Left),
            ev(6, 3, ShareStarted),
            ev(10, 1, Joined),
            ev(11, 1, Joined),
            ev(12, 1, ShareStarted),
            ev(13, 1, ShareStarted),
            ev(20, 1, Left),
            ev(21, 1, Left),
        ];
        let calls = segment(&events, &HashSet::new());
        assert_eq!(calls.len(), 1);
        let kinds: Vec<_> = calls[0].events.iter().map(|e| e.kind).collect();
        assert_eq!(kinds, [Joined, ShareStarted, Left]);
    }

    #[test]
    fn an_open_call_is_ongoing_only_while_someone_is_really_there() {
        let events = [ev(10, 1, Joined), ev(20, 2, Joined)];
        let live = HashSet::from([user(2)]);
        assert_eq!(segment(&events, &live)[0].ended_at, None);
        let calls = segment(&events, &HashSet::new());
        assert_eq!(
            calls[0].ended_at,
            Some(20),
            "a missed leave closes it at its last event"
        );
    }
}
