// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one writer of call transcript marks, for the Mark button, a hotkey and the
//! spoken command alike. A kept or removed mark goes live to the same people its
//! transcript's lines do: whoever is in the call and may read the transcript.

use std::sync::Arc;

use crate::http::AppState;
use crate::hub::Event;
use crate::ids::{CallTranscriptId, CallTranscriptMarkId, ChannelId, UserId};
use crate::store::{NewMark, PutMark, TranscriptMark, now_ms};
use crate::voice::Listing;

/// Keeps `new` and tells `audience` about it when it is new.
pub async fn add(
    state: &AppState,
    channel: ChannelId,
    new: &NewMark<'_>,
    audience: &[UserId],
) -> anyhow::Result<PutMark> {
    let put = state.store.put_call_transcript_mark(new, now_ms()).await?;
    if let PutMark::Created(mark) = &put {
        publish(
            state,
            channel,
            (mark.transcript_id, mark.id),
            Some(mark.clone()),
            audience,
        );
    }
    Ok(put)
}

/// Keeps a mark said in a call. Its frame goes to the call's roster, asked of the
/// SFU off the call-audio loop when the live roster cannot be trusted yet.
pub async fn add_spoken(
    state: &AppState,
    channel: ChannelId,
    new: &NewMark<'_>,
) -> anyhow::Result<()> {
    let PutMark::Created(mark) = state.store.put_call_transcript_mark(new, now_ms()).await? else {
        return Ok(());
    };
    let ids = (mark.transcript_id, mark.id);
    if let Some(audience) = state.voice.trusted_roster(channel) {
        publish(state, channel, ids, Some(mark), &audience);
        return Ok(());
    }
    let state = state.clone();
    tokio::spawn(async move {
        let audience = state.voice.in_call(channel, Listing::Shared).await;
        publish(&state, channel, ids, Some(mark), &audience);
    });
    Ok(())
}

/// Tells `audience` a mark is gone.
pub fn removed(
    state: &AppState,
    channel: ChannelId,
    ids: (CallTranscriptId, CallTranscriptMarkId),
    audience: &[UserId],
) {
    publish(state, channel, ids, None, audience);
}

fn publish(
    state: &AppState,
    channel: ChannelId,
    (transcript_id, mark_id): (CallTranscriptId, CallTranscriptMarkId),
    mark: Option<TranscriptMark>,
    audience: &[UserId],
) {
    if audience.is_empty() {
        return;
    }
    state.hub.publish(Event::CallTranscriptMarkChanged {
        channel_id: channel,
        transcript_id,
        mark_id,
        mark: mark.map(Arc::new),
        audience: audience.into(),
    });
}
