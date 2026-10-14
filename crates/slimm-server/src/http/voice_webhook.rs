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
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode, header};
use axum::routing::post;

use super::AppState;
use super::extract::enforce;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::Class;
use crate::store::VoiceEventKind;
use crate::voice::{self, RoomLiveState, WebhookError, WebhookEvent};

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
    State(state): State<AppState>,
    parts: Parts,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    if enforce(&state, &parts, None, Class::LiveKitWebhook).is_err() {
        return StatusCode::TOO_MANY_REQUESTS;
    }

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

    apply(&state, event);
    StatusCode::NO_CONTENT
}

/// Turns a verified webhook event into a hub publish, or nothing for an
/// event this server does not act on (`room_started`, egress events, a track
/// that is not screen-share sourced, and so on).
fn apply(state: &AppState, event: WebhookEvent) {
    let Some(channel_id) = event
        .room
        .as_ref()
        .and_then(|room| voice::channel_for_room(&room.name))
    else {
        return;
    };
    let Some(user_id) = event
        .participant
        .as_ref()
        .and_then(|p| p.identity.parse().ok().map(UserId))
    else {
        return;
    };
    let live_state = state.voice.live_state();

    match event.event.as_str() {
        "participant_joined" => {
            // Recorded even when not a new transition: a duplicate is harmless to the history, a missed join is not.
            record(state, channel_id, user_id, VoiceEventKind::Joined);
            if live_state.mark_joined(channel_id, user_id) {
                state.hub.publish(Event::VoiceParticipantJoined {
                    channel_id,
                    user_id,
                });
            }
        }
        "participant_left" => {
            record(state, channel_id, user_id, VoiceEventKind::Left);
            if live_state.mark_left(channel_id, user_id) {
                state.hub.publish(Event::VoiceParticipantLeft {
                    channel_id,
                    user_id,
                });
            }
        }
        "track_published" => {
            publish_share_change(state, &live_state, channel_id, user_id, &event, true);
        }
        "track_unpublished" => {
            publish_share_change(state, &live_state, channel_id, user_id, &event, false);
        }
        _ => {}
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
    user_id: UserId,
    event: &WebhookEvent,
    started: bool,
) {
    let Some(track) = &event.track else { return };
    if !voice::is_screen_share_source(&track.source) {
        return;
    }
    let is_real_transition = if started {
        live_state.track_published(channel_id, user_id, &track.sid)
    } else {
        live_state.track_unpublished(channel_id, user_id, &track.sid)
    };
    if is_real_transition {
        let kind = if started {
            VoiceEventKind::ShareStarted
        } else {
            VoiceEventKind::ShareStopped
        };
        record(state, channel_id, user_id, kind);
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
