// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The values a transition hands out: outcomes, event ids and accepted segments.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use uuid::Uuid;

use super::session::{Consumer, Effect};
use super::view::CallAudioView;
use crate::ids::{ChannelId, UserId};

/// Why a request was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestError {
    Unavailable,
    /// The listener is at its `max_sessions`.
    Busy,
    AlreadyOn,
    /// Milliseconds left of the wait after a decline.
    Cooldown(i64),
    TooManyPeople,
}

/// What a transition left behind, copied out so effects run without the lock.
#[derive(Debug, Clone)]
pub struct Outcome {
    pub session_id: Uuid,
    pub channel: ChannelId,
    pub consumer: Consumer,
    pub effects: Vec<Effect>,
    pub view: CallAudioView,
    pub include: Vec<UserId>,
    pub started_at_ms: Option<i64>,
    pub ids: EventIds,
}

/// Mints `call-audio:<session>:<n>` ids, once each.
#[derive(Debug, Clone)]
pub struct EventIds {
    pub(super) session: Uuid,
    counter: Arc<AtomicU64>,
    sent: Arc<AtomicU64>,
}

impl PartialEq for EventIds {
    fn eq(&self, other: &Self) -> bool {
        self.session == other.session
    }
}

impl Eq for EventIds {}

impl EventIds {
    pub(super) fn new(session: Uuid) -> Self {
        Self {
            session,
            counter: Arc::default(),
            sent: Arc::default(),
        }
    }

    pub(super) fn count_sent(&self) {
        self.sent.fetch_add(1, Ordering::Relaxed);
    }

    pub fn mint(&self) -> String {
        let n = self.counter.fetch_add(1, Ordering::Relaxed) + 1;
        format!("call-audio:{}:{n}", self.session)
    }

    /// Segments handed to the module so far.
    pub fn segments_sent(&self) -> u64 {
        self.sent.load(Ordering::Relaxed)
    }
}

/// A segment that passed every check, ready for the module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcceptedSegment {
    pub channel: ChannelId,
    pub consumer: Consumer,
    pub session_id: Uuid,
    pub user_id: UserId,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    pub language: Option<String>,
    pub segment_id: String,
    pub ids: EventIds,
}
