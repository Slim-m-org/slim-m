// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server as a call-audio consumer (decision 0113): a transcript row per
//! session, a line per accepted segment, and the `always` mode's start at the
//! first join. Segment text goes to the database, and live only to the people
//! in the call who may read it.

use std::sync::Arc;

use super::session::{Consumer, Subject};
use super::{AcceptedSegment, Outcome};
use crate::http::AppState;
use crate::hub::Event;
use crate::ids::{CallTranscriptId, ChannelId, UserId};
use crate::store::{NewTranscript, NewTranscriptLine, TranscriptLine, TranscriptionMode, now_ms};

/// What a person is shown about the server's own transcript.
pub fn subject() -> Subject {
    Subject {
        consumer: Consumer::Transcript,
        module_name: "Call transcript".to_owned(),
        purpose: "Writes down what is said in this call.".to_owned(),
        keeps: "Each line, who said it and when, as part of the call, until the Space's retention window passes or a moderator deletes it.".to_owned(),
    }
}

fn id_of(outcome: &Outcome) -> CallTranscriptId {
    CallTranscriptId(outcome.session_id)
}

fn changed(state: &AppState, outcome: &Outcome, ended: bool) {
    state.hub.publish(Event::CallTranscriptChanged {
        channel_id: outcome.channel,
        transcript_id: id_of(outcome),
        ended,
    });
}

/// Writes the transcript row for a session that is about to start; false when it could not.
pub async fn open(state: &AppState, outcome: &Outcome) -> bool {
    let automatic = outcome.view.automatic;
    let new = NewTranscript {
        id: id_of(outcome),
        channel_id: outcome.channel,
        started_at: outcome.started_at_ms.unwrap_or_else(now_ms),
        mode: if automatic {
            TranscriptionMode::Always
        } else {
            TranscriptionMode::OnRequest
        },
        started_by: (!automatic)
            .then(|| outcome.view.asked_by.as_deref()?.parse().ok().map(UserId))
            .flatten(),
    };
    if let Err(err) = state.store.begin_call_transcript(&new).await {
        tracing::warn!(%err, "could not open a call transcript");
        return false;
    }
    changed(state, outcome, false);
    true
}

/// Drops the row of a session whose listener never started.
pub async fn discard(state: &AppState, outcome: &Outcome) {
    if let Err(err) = state.store.delete_call_transcript(id_of(outcome)).await {
        tracing::warn!(%err, "could not drop an unstarted call transcript");
    }
}

pub async fn close(state: &AppState, outcome: &Outcome) {
    if let Err(err) = state
        .store
        .end_call_transcript(id_of(outcome), now_ms())
        .await
    {
        tracing::warn!(%err, "could not close a call transcript");
    }
    changed(state, outcome, true);
}

pub async fn write_line(state: &AppState, segment: &AcceptedSegment) {
    let id = CallTranscriptId(segment.session_id);
    let line = NewTranscriptLine {
        speaker: segment.user_id,
        at: segment.start_ms,
        end_at: Some(segment.end_ms.max(segment.start_ms)),
        language: segment.language.as_deref(),
        text: &segment.text,
    };
    match state.store.append_call_transcript_line(id, &line).await {
        Ok(stored) => on_line(state, (segment.channel, id), stored).await,
        Err(err) => tracing::warn!(%err, "could not write a call transcript line"),
    }
}

/// Runs once for each line as it is kept: today it sends the line to the people in the call.
async fn on_line(
    state: &AppState,
    (channel, id): (ChannelId, CallTranscriptId),
    line: TranscriptLine,
) {
    let audience: Arc<[UserId]> = in_call(state, channel).await.into();
    if audience.is_empty() {
        return;
    }
    state.hub.publish(Event::CallTranscriptLine {
        channel_id: channel,
        transcript_id: id,
        audience,
        line: Arc::new(line),
    });
}

/// The webhook roster, or the SFU's own list when the roster is empty or predates a restart.
async fn in_call(state: &AppState, channel: ChannelId) -> Vec<UserId> {
    let live = state.voice.live_state();
    let present = live.present(channel);
    if !present.is_empty() && live.is_reconciled(channel) {
        return present;
    }
    match state.voice.list_participants_shared(channel).await {
        Ok(listed) => listed.into_iter().map(|p| p.user_id).collect(),
        Err(_) => present,
    }
}
