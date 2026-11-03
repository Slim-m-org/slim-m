// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Call-audio events (decision 0105). They go straight to the one module the
//! call agreed to, never over the hub, so no websocket subscriber can be sent
//! a segment by a later change to a frame. The module needs no subscription
//! for them; delivery checks that `call.audio` is still approved instead.

use std::sync::Arc;

use super::queue::Origin;
use super::wire::{EventData, ModuleEvent};
use crate::call_audio::{AcceptedSegment, Outcome};
use crate::http::AppState;
use crate::store::now_ms;

/// Event names this module delivers, in the order the decision lists them.
pub(crate) const STARTED: &str = "call.audio.started";
pub(crate) const PARTICIPANT: &str = "call.audio.participant";
pub(crate) const SEGMENT: &str = "call.audio.segment";
pub(crate) const STOPPED: &str = "call.audio.stopped";

/// Whether `kind` is one of the four, which delivery treats differently.
pub(super) fn is_call_audio(kind: &str) -> bool {
    matches!(kind, STARTED | PARTICIPANT | SEGMENT | STOPPED)
}

fn push(state: &AppState, module_id: &str, kind: &'static str, id: String, data: EventData) {
    let body = serde_json::to_string(&ModuleEvent {
        contract: format!("event/{}", crate::module_runtime::EVENT_CONTRACT),
        event: kind,
        id,
        at_ms: now_ms(),
        data,
    });
    match body {
        Ok(body) => {
            let body: Arc<str> = body.into();
            state
                .dock
                .event_queues()
                .push(module_id, (kind, Origin::default()), body);
        }
        Err(err) => tracing::warn!(%err, "could not render a call-audio event"),
    }
}

pub(crate) fn started(state: &AppState, outcome: &Outcome) {
    let data = EventData::CallAudioStarted {
        session_id: outcome.session_id.to_string(),
        channel_id: outcome.channel.to_string(),
        started_at_ms: outcome.started_at_ms.unwrap_or_else(now_ms),
        included: outcome.include.iter().map(ToString::to_string).collect(),
    };
    push(state, &outcome.module_id, STARTED, outcome.ids.mint(), data);
}

pub(crate) fn participant(
    state: &AppState,
    outcome: &Outcome,
    user_id: crate::ids::UserId,
    included: bool,
) {
    let data = EventData::CallAudioParticipant {
        session_id: outcome.session_id.to_string(),
        channel_id: outcome.channel.to_string(),
        user_id: user_id.to_string(),
        included,
    };
    push(
        state,
        &outcome.module_id,
        PARTICIPANT,
        outcome.ids.mint(),
        data,
    );
}

pub(crate) fn segment(state: &AppState, accepted: &AcceptedSegment) {
    let data = EventData::CallAudioSegment {
        session_id: accepted.session_id.to_string(),
        channel_id: accepted.channel.to_string(),
        segment_id: accepted.segment_id.clone(),
        user_id: accepted.user_id.to_string(),
        start_ms: accepted.start_ms,
        end_ms: accepted.end_ms,
        text: accepted.text.clone(),
        language: accepted.language.clone(),
    };
    push(
        state,
        &accepted.module_id,
        SEGMENT,
        accepted.segment_id.clone(),
        data,
    );
}

pub(crate) fn stopped(state: &AppState, outcome: &Outcome, reason: &'static str) {
    let data = EventData::CallAudioStopped {
        session_id: outcome.session_id.to_string(),
        channel_id: outcome.channel.to_string(),
        stopped_at_ms: now_ms(),
        reason,
        segments_sent: outcome.ids.segments_sent(),
    };
    push(state, &outcome.module_id, STOPPED, outcome.ids.mint(), data);
}
