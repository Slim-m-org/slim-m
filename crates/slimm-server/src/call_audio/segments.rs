// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Taking one transcribed segment from the listener: checked against the include
//! set last sent, rate limited, and stamped with ids.

use uuid::Uuid;

use super::{AcceptedSegment, CallAudio, filter, live_or_draining, lock, protocol};
use crate::ids::UserId;

impl CallAudio {
    /// Checks one segment from the listener against the set last sent.
    pub fn accept_segment(
        &self,
        frame: &protocol::FromListener,
        now: i64,
    ) -> Option<AcceptedSegment> {
        let protocol::FromListener::Segment {
            session,
            identity,
            start_ms,
            end_ms,
            text,
            language,
        } = frame
        else {
            return None;
        };
        let id: Uuid = session.parse().ok()?;
        let inner = self.inner.as_ref()?;
        let mut state = lock(&inner.state);
        let (channel, live) = live_or_draining(&mut state, id)?;
        let started = live.anchor_ms.or(live.session.started_at_ms)?;
        if !live.sent.contains(identity) {
            live.rate.count_drop();
            tracing::warn!(session, "dropped a segment from outside the include set");
            return None;
        }
        let text = filter::cut_text(text)?;
        if !live.rate.admit(now) {
            return None;
        }
        let user_id = UserId(identity.parse().ok()?);
        live.ids.count_sent();
        let segment_id = live.ids.mint();
        Some(AcceptedSegment {
            channel,
            consumer: live.session.subject.consumer.clone(),
            session_id: live.ids.session,
            user_id,
            start_ms: started + start_ms,
            end_ms: started + end_ms,
            text,
            language: language.as_deref().and_then(filter::language_tag),
            listens_for: live.session.subject.listens_for.clone(),
            segment_id,
            ids: live.ids.clone(),
        })
    }
}
