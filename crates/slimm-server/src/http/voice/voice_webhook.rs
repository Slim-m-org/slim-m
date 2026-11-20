// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Receiving LiveKit's own webhook: join, leave and screen-share events,
//! straight from the SFU rather than inferred from client self-report.
//!
//! See `docs/decisions/0032-voice-participant-webhooks.md`. No `Authed`:
//! LiveKit has no session, so this authenticates the same way its own server
//! SDKs verify each other's deliveries, by the request's own JWT signature
//! (`voice::VoiceService::verify_webhook`), never a bearer token.

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::routing::post;

use super::super::AppState;
use super::super::extract::{LIVEKIT_WEBHOOK, RateLimited};
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::store::{SessionScope, VoiceEventKind};
use crate::voice::{self, RoomLiveState, WebhookError, WebhookEvent};
use crate::voice_notify::Activity;
use crate::voice_session_sweeps::publish_closed;

pub fn routes() -> Router<AppState> {
    Router::new().route("/voice/webhook", post(receive))
}

/// Verifies and applies one LiveKit webhook delivery.
///
/// Always `204` once the signature verifies, including for an event this
/// server takes no action on: LiveKit retries any non-2xx response, and an
/// event we deliberately ignore is not a delivery failure. A bad signature
/// is `403`; a deployment with no SFU configured (so no secret to verify
/// against) is `501`, the same code every other voice route uses for it.
async fn receive(
    _limited: RateLimited<LIVEKIT_WEBHOOK>,
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    let authorization = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let event = match state.voice.verify_webhook(&body, authorization) {
        Ok(event) => event,
        Err(WebhookError::Unavailable) => return StatusCode::NOT_IMPLEMENTED,
        Err(WebhookError::Malformed | WebhookError::BadSignature | WebhookError::Expired) => {
            return StatusCode::FORBIDDEN;
        }
    };

    tracing::debug!(
        event = %event.event,
        room = event.room.as_ref().map(|r| r.name.as_str()),
        participant = event.participant.as_ref().map(|p| p.identity.as_str()),
        reason = ?event.participant.as_ref().and_then(|p| p.disconnect_reason.as_ref()),
        "voice: livekit webhook"
    );
    if let Some(channel_id) = foreign_channel(&state, &event).await {
        tracing::debug!(
            %channel_id,
            event = %event.event,
            "ignored a webhook for a room this deployment never had"
        );
        return StatusCode::NO_CONTENT;
    }
    track_session(&state, &event).await;
    let room_finished = room_finished_channel(&event);
    reconcile_roster(&state, &event).await;
    let published = event.participant.as_ref().is_some_and(|p| p.is_publisher);
    let joined_at_ms = event.participant_joined_at_ms();
    let presence = apply(&state, event);
    if let Some((channel_id, user_id, true)) = presence {
        settle_join(&state, channel_id, user_id, joined_at_ms);
        if !published {
            announce_now(&state, channel_id, user_id);
        }
    }
    track_call_audio(&state, room_finished, presence).await;
    StatusCode::NO_CONTENT
}

/// The channel the event's room names when this deployment never had it: one LiveKit can serve
/// several deployments, and its webhook brings every one of them each room's events.
async fn foreign_channel(state: &AppState, event: &WebhookEvent) -> Option<ChannelId> {
    let channel_id = event.channel_id()?;
    match state.store.channel_including_deleted(channel_id).await {
        Ok(None) => Some(channel_id),
        Ok(Some(_)) | Err(_) => None,
    }
}

/// A join the SFU let in is checked for access, and one that stays ends the member's older call elsewhere.
fn settle_join(
    state: &AppState,
    channel_id: ChannelId,
    user_id: UserId,
    joined_at_ms: Option<i64>,
) {
    let state = state.clone();
    tokio::spawn(async move {
        if super::voice_access::evict_join_without_access(&state, user_id, channel_id).await {
            super::voice_one_call::end_older_calls(&state, user_id, channel_id, joined_at_ms).await;
        }
    });
}

/// Has the SFU announce a join that published nothing, which it would otherwise batch for up to
/// 3 s; detached, since a failure only costs that wait.
fn announce_now(state: &AppState, channel_id: ChannelId, user_id: UserId) {
    let voice = state.voice.clone();
    tokio::spawn(async move {
        if let Err(err) = voice.announce_participant(channel_id, user_id).await {
            tracing::warn!(?err, %channel_id, "could not announce a join to the call");
        }
    });
}

/// Keeps the member's voice session row (decision 0091) in step with the
/// event. Awaited, so a leave never races the join it closes; a failure is
/// logged and the delivery still succeeds, since LiveKit would only retry it.
async fn track_session(state: &AppState, event: &WebhookEvent) {
    let Some(channel_id) = event.channel_id() else {
        return;
    };
    let at = crate::store::now_ms();
    let store = &state.store;
    let outcome = if event.event == "room_finished" {
        store
            .close_voice_sessions(SessionScope::Channel(channel_id), at)
            .await
            .map(|closed| publish_closed(&state.hub, &closed))
    } else {
        let Some(participant) = &event.participant else {
            return;
        };
        let Some(user_id) = participant.identity.parse().ok().map(UserId) else {
            return;
        };
        match event.event.as_str() {
            "participant_joined" => store
                .open_voice_session_closing(channel_id, user_id, &participant.sid, at)
                .await
                .map(|(_, closed)| publish_closed(&state.hub, &closed)),
            "participant_left" => store
                .close_voice_sessions(SessionScope::Sid(user_id, &participant.sid), at)
                .await
                .map(|closed| publish_closed(&state.hub, &closed)),
            _ => return,
        }
    };
    if let Err(err) = outcome {
        tracing::warn!(%err, "could not update a voice session");
    }
}

/// Reads the SFU's members into the live state before the first participant event for a channel
/// after a restart is applied, so that event sees everyone already on the call.
async fn reconcile_roster(state: &AppState, event: &WebhookEvent) {
    if event.participant.is_none() || event.event == "room_finished" {
        return;
    }
    if let Some(channel_id) = event.channel_id() {
        state.voice.reconcile_live_state(channel_id).await;
    }
}

fn room_finished_channel(event: &WebhookEvent) -> Option<ChannelId> {
    if event.event != "room_finished" {
        return None;
    }
    event.channel_id()
}

/// A real join or leave `apply` saw: the channel, the member, and whether they joined.
type Presence = (ChannelId, UserId, bool);

/// Tells call audio who came and went (decision 0105). Bots are never asked or heard.
async fn track_call_audio(
    state: &AppState,
    room_finished: Option<ChannelId>,
    presence: Option<Presence>,
) {
    if !state.call_audio.is_enabled() {
        return;
    }
    let now = crate::store::now_ms();
    let outcome = if let Some(channel) = room_finished {
        state.call_audio.end(
            channel,
            crate::call_audio::session::EndReason::CallEnded,
            now,
        )
    } else if let Some((channel, user, joined)) = presence {
        if state.store.is_bot(user).await.unwrap_or(true) {
            return;
        }
        if joined {
            let heard = state.call_audio.joined(channel, user, now);
            if heard.is_none() {
                super::voice_transcription::ensure_always(state, channel, user).await;
            }
            heard
        } else {
            state.call_audio.left(channel, user, now)
        }
    } else {
        return;
    };
    if let Some(outcome) = outcome {
        crate::call_audio::runtime::apply(state, outcome).await;
    }
}

/// Turns a verified webhook event into a hub publish, or nothing for an
/// event this server does not act on (`room_started`, egress events, a track
/// that is not screen-share sourced, and so on). Returns a real join or leave.
fn apply(state: &AppState, event: WebhookEvent) -> Option<Presence> {
    let channel_id = event.channel_id()?;
    state.voice.roster_cache().invalidate(channel_id);
    let live_state = state.voice.live_state();
    if event.event == "room_finished" {
        live_state.forget_room(channel_id);
        return None;
    }
    let (user_id, sid) = event
        .participant
        .as_ref()
        .and_then(|p| Some((p.identity.parse().ok().map(UserId)?, p.sid.as_str())))?;
    let mut presence = None;

    match event.event.as_str() {
        "participant_joined" => {
            // Recorded even when not a new transition: a duplicate is harmless to the history, a missed join is not.
            record(state, channel_id, user_id, VoiceEventKind::Joined);
            let present_before =
                live_state.present_before(channel_id, event.participant_joined_at_ms());
            if live_state.mark_joined(channel_id, user_id, sid) {
                let activity = super::voice_notice::join_activity(&present_before, user_id);
                super::voice_notice::announce(state, channel_id, user_id, activity);
                presence = Some((channel_id, user_id, true));
                state.hub.publish(Event::VoiceParticipantJoined {
                    channel_id,
                    user_id,
                });
            }
        }
        "participant_left" => {
            record(state, channel_id, user_id, VoiceEventKind::Left);
            if live_state.mark_left(channel_id, user_id, sid) {
                presence = Some((channel_id, user_id, false));
                state.hub.publish(Event::VoiceParticipantLeft {
                    channel_id,
                    user_id,
                });
            }
            let (store, voice, hub) = (state.store.clone(), state.voice.clone(), state.hub.clone());
            tokio::spawn(async move {
                crate::room_cleanup::remove_if_empty(&store, &voice, &hub, channel_id).await;
            });
        }
        "track_published" => {
            nudge_if_microphone(state, channel_id, &event);
            publish_share_change(state, &live_state, channel_id, (user_id, sid), &event, true);
        }
        "track_unpublished" => {
            nudge_if_microphone(state, channel_id, &event);
            publish_share_change(
                state,
                &live_state,
                channel_id,
                (user_id, sid),
                &event,
                false,
            );
        }
        _ => {}
    }
    presence
}

/// Publishing or dropping a microphone track flips a roster's `is_muted` with no mute report from
/// the caller, so this is what tells viewers outside the call to read it again.
fn nudge_if_microphone(state: &AppState, channel_id: ChannelId, event: &WebhookEvent) {
    let is_microphone = event
        .track
        .as_ref()
        .is_some_and(|track| track.source.eq_ignore_ascii_case("MICROPHONE"));
    if is_microphone {
        state
            .hub
            .publish(Event::VoiceActivityChanged { channel_id });
    }
}

/// The shared half of the `track_published`/`track_unpublished` arms: only a
/// screen-share-sourced track can change `is_sharing_screen`, and only when
/// [`voice::RoomLiveState`] says this track is the one that actually flips
/// it (the first to start sharing, or the last to stop).
fn publish_share_change(
    state: &AppState,
    live_state: &RoomLiveState,
    channel_id: ChannelId,
    (user_id, sid): (UserId, &str),
    event: &WebhookEvent,
    started: bool,
) {
    let Some(track) = &event.track else { return };
    if !voice::is_screen_share_source(&track.source) {
        return;
    }
    let is_real_transition = if started {
        live_state.track_published(channel_id, (user_id, sid), &track.sid)
    } else {
        live_state.track_unpublished(channel_id, (user_id, sid), &track.sid)
    };
    if is_real_transition {
        let kind = if started {
            VoiceEventKind::ShareStarted
        } else {
            VoiceEventKind::ShareStopped
        };
        record(state, channel_id, user_id, kind);
        if started {
            super::voice_notice::announce(state, channel_id, user_id, Activity::Streaming);
        }
        state.hub.publish(Event::VoiceScreenShareChanged {
            channel_id,
            user_id,
            is_sharing_screen: started,
        });
    }
}

/// The last stamp handed out, so two events in the same millisecond still
/// read back in the order they arrived.
static LAST_STAMP: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

/// Now in milliseconds, or one past the last stamp if that is later.
fn next_stamp() -> i64 {
    use std::sync::atomic::Ordering;
    let mut last = LAST_STAMP.load(Ordering::Relaxed);
    loop {
        let next = crate::store::now_ms().max(last + 1);
        match LAST_STAMP.compare_exchange_weak(last, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(seen) => last = seen,
        }
    }
}

/// Adds one event to the channel's call history (decision 0066), stamped on
/// arrival so the write can land in any order.
fn record(state: &AppState, channel_id: ChannelId, user_id: UserId, kind: VoiceEventKind) {
    let at = next_stamp();
    let store = state.store.clone();
    tokio::spawn(async move {
        if let Err(err) = store
            .record_voice_event(channel_id, user_id, kind, at)
            .await
        {
            tracing::warn!(%err, "could not record a voice call event");
        }
    });
}
