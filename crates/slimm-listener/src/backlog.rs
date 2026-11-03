// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Speech waiting for the transcriber. At 30 s of untranscribed speech the
//! oldest utterance is dropped and counted; staying full for 120 s means the
//! machine cannot keep up and the session ends with `overload`.

use std::collections::VecDeque;

use crate::endpoint::Utterance;

/// Untranscribed speech held before the oldest is dropped.
pub const MAX_BACKLOG_MS: i64 = 30_000;
/// How long the backlog may stay full before the session gives up.
pub const OVERLOAD_AFTER_MS: i64 = 120_000;
/// A session's length limit.
pub const TIME_LIMIT_MS: i64 = 4 * 60 * 60 * 1000;

/// An utterance and whose it is.
#[derive(Debug, Clone, PartialEq)]
pub struct Queued {
    pub identity: String,
    pub utterance: Utterance,
}

#[derive(Default)]
pub struct Backlog {
    queue: VecDeque<Queued>,
    queued_ms: i64,
    dropped: u64,
    full_since: Option<i64>,
}

impl Backlog {
    /// Adds an utterance at `now` (any steady millisecond clock), dropping the oldest to fit.
    pub fn push(&mut self, item: Queued, now: i64) {
        self.queued_ms += item.utterance.duration_ms();
        self.queue.push_back(item);
        while self.queued_ms > MAX_BACKLOG_MS && self.queue.len() > 1 {
            if let Some(oldest) = self.queue.pop_front() {
                self.queued_ms -= oldest.utterance.duration_ms();
                self.dropped += 1;
            }
        }
        self.note_fullness(now);
    }

    /// The oldest utterance, for a free worker.
    pub fn pop(&mut self, now: i64) -> Option<Queued> {
        let item = self.queue.pop_front()?;
        self.queued_ms -= item.utterance.duration_ms();
        self.note_fullness(now);
        Some(item)
    }

    /// Forgets what a person said once they are no longer included.
    pub fn forget(&mut self, identity: &str, now: i64) {
        self.queue.retain(|q| q.identity != identity);
        self.queued_ms = self.queue.iter().map(|q| q.utterance.duration_ms()).sum();
        self.note_fullness(now);
    }

    fn note_fullness(&mut self, now: i64) {
        let full = self.queued_ms >= MAX_BACKLOG_MS - 1_000;
        match (full, self.full_since) {
            (true, None) => self.full_since = Some(now),
            (false, Some(_)) => self.full_since = None,
            _ => {}
        }
    }

    /// Whether it has stayed full long enough to end the session.
    pub fn overloaded(&self, now: i64) -> bool {
        self.full_since
            .is_some_and(|since| now - since >= OVERLOAD_AFTER_MS)
    }

    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    pub fn queued_ms(&self) -> i64 {
        self.queued_ms
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(who: &str, ms: i64) -> Queued {
        Queued {
            identity: who.into(),
            utterance: Utterance {
                start_ms: 0,
                end_ms: ms,
                pcm: Vec::new(),
            },
        }
    }

    #[test]
    fn it_serves_the_oldest_first() {
        let mut backlog = Backlog::default();
        backlog.push(item("a", 1_000), 0);
        backlog.push(item("b", 1_000), 0);
        assert_eq!(backlog.pop(0).unwrap().identity, "a");
        assert_eq!(backlog.pop(0).unwrap().identity, "b");
        assert!(backlog.pop(0).is_none());
    }

    #[test]
    fn past_thirty_seconds_the_oldest_is_dropped_and_counted() {
        let mut backlog = Backlog::default();
        for who in ["a", "b", "c", "d"] {
            backlog.push(item(who, 10_000), 0);
        }
        assert_eq!(backlog.dropped(), 1);
        assert_eq!(backlog.queued_ms(), 30_000);
        assert_eq!(backlog.pop(0).unwrap().identity, "b", "a was the oldest");
    }

    #[test]
    fn staying_full_for_two_minutes_is_overload_and_draining_resets_it() {
        let mut backlog = Backlog::default();
        for _ in 0..4 {
            backlog.push(item("a", 10_000), 1_000);
        }
        assert!(!backlog.overloaded(1_000 + OVERLOAD_AFTER_MS - 1));
        assert!(backlog.overloaded(1_000 + OVERLOAD_AFTER_MS));
        while backlog.pop(60_000).is_some() {}
        assert!(!backlog.overloaded(1_000 + 10 * OVERLOAD_AFTER_MS));
    }

    #[test]
    fn forgetting_a_person_removes_only_their_speech() {
        let mut backlog = Backlog::default();
        backlog.push(item("a", 1_000), 0);
        backlog.push(item("b", 2_000), 0);
        backlog.forget("a", 0);
        assert_eq!(backlog.queued_ms(), 2_000);
        assert_eq!(backlog.pop(0).unwrap().identity, "b");
    }
}
