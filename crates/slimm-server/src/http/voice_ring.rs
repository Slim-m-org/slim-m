// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ringing the other side of a DM call, and declining an incoming one.
//!
//! Split out of `voice.rs` to keep that file under the line budget, but
//! still the same check-in-front shape every route there already uses: the
//! ordinary DM permission check (`store/dms.rs::dm_permissions`, reached
//! through [`crate::store::Store::permissions_in_channel`]) is what refuses
//! a blocked party here exactly as it already refuses one a token or a
//! heartbeat - `CONNECT` is one of the bits a block removes, and starting a
//! ring is gated on it the same way minting a token already is.
//!
//! Answering has no route of its own: a callee's first heartbeat for this
//! channel already reaching `heartbeat` in `voice.rs` is what counts as
//! answering, so there is nothing more for this file to do about it. This
//! file only owns the two routes an ordinary join cannot express - starting
//! a ring, and refusing one without joining anything.
//!
//! Tearing down an unanswered ring's own caller lives in `lib.rs`, next to
//! `sweep_stale_voice_calls`, on the same short-interval sweep shape.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::voice::{CallRingOutcome, VoiceError};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/ring", post(ring))
        .route("/channels/{channel_id}/voice/ring/decline", post(decline))
        .route("/voice/rings/incoming", get(incoming))
}

#[derive(Serialize)]
struct RingResponse {
    ring_id: String,
    timeout_ms: i64,
}

#[derive(Serialize)]
struct IncomingRing {
    channel_id: String,
    ring_id: String,
    caller_id: String,
    remaining_ms: i64,
}

#[derive(Serialize)]
struct IncomingRings {
    rings: Vec<IncomingRing>,
}

/// The caller's own outstanding rings, for a client that connected after the
/// `call.ringing` frame was broadcast (a cold launch from a VoIP push).
///
/// Keyed on the authenticated account as the callee, so a ring is never
/// visible to anyone but its recipient. Nothing is claimed or consumed.
async fn incoming(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<Json<IncomingRings>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let rings = state
        .voice
        .rings()
        .outstanding_for_at(ctx.user_id, std::time::Instant::now())
        .into_iter()
        .map(|(channel_id, ring_id, caller_id, left)| IncomingRing {
            channel_id: channel_id.to_string(),
            ring_id: ring_id.to_string(),
            caller_id: caller_id.to_string(),
            remaining_ms: left.as_millis() as i64,
        })
        .collect();
    Ok(Json(IncomingRings { rings }))
}

/// Starts ringing the other side of a DM call.
///
/// `VIEW_CHANNEL` and `CONNECT` are the gate, the same pair minting a token
/// already requires: a ring for a room the caller could not join tells the
/// other side nothing real, and a blocked party never reaches this far.
///
/// Refuses anything that is not a DM between the caller and exactly one
/// other account (`NotFound`): ringing is meaningless for a channel with any
/// other shape, and a caller's own personal space (a DM with themself) has
/// nobody on the other end to ring.
///
/// A second ring for the same channel replaces whatever was already
/// outstanding - see [`crate::voice::CallRings`] - since a caller trying
/// again is the same call, not a second one stacked on top of the first.
async fn ring(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<RingResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Ring)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if !state.voice.is_enabled() {
        return Err(ApiError::NotConfigured(
            "this server has no voice configured",
        ));
    }

    let Some((user_a, user_b)) = state.store.dm_pair(channel_id).await? else {
        return Err(ApiError::NotFound("no such DM channel"));
    };
    let callee = match (user_a == ctx.user_id, user_b == ctx.user_id) {
        (true, true) => return Err(ApiError::NotFound("a personal space has nobody to ring")),
        (true, false) => user_b,
        (false, true) => user_a,
        (false, false) => return Err(ApiError::Forbidden),
    };

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }

    let ring_id = state.voice.rings().start(channel_id, ctx.user_id, callee);
    state.hub.publish(Event::CallRinging {
        channel_id,
        ring_id,
        caller_id: ctx.user_id,
    });
    state.push.notify_call_ring(
        state.store.clone(),
        channel_id,
        ring_id,
        ctx.user_id,
        callee,
    );

    Ok(Json(RingResponse {
        ring_id: ring_id.to_string(),
        timeout_ms: crate::voice::RING_TIMEOUT.as_millis() as i64,
    }))
}

/// Declines an incoming DM call ring.
///
/// No `CONNECT` check, unlike every other voice route but `forget_heartbeat`:
/// refusing a call reveals and grants nothing about the room itself, only
/// that this caller chose not to join it, so a permission revoked mid-ring
/// must not be what blocks declining it.
///
/// Idempotent: declining a ring that already ended some other way (answered,
/// canceled, timed out) finds nothing outstanding and simply succeeds.
///
/// Evicts the caller from the SFU room on a real decline, best-effort: they
/// may already have joined while the ring was outstanding, and a decline
/// must free the room now rather than waiting on the ring's own timeout.
async fn decline(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if let Some((ring_id, caller_id)) = state.voice.rings().decline(channel_id, ctx.user_id) {
        state.hub.publish(Event::CallRingEnded {
            channel_id,
            ring_id,
            outcome: CallRingOutcome::Declined,
        });
        record_call(
            &state,
            channel_id,
            ring_id,
            caller_id,
            CallRingOutcome::Declined,
        )
        .await;
        match state.voice.remove_participant(channel_id, caller_id).await {
            Ok(()) | Err(VoiceError::Unavailable) => {}
            Err(VoiceError::Internal(err)) => {
                tracing::warn!(error = %err, %channel_id, "failed to remove a caller after a declined ring");
            }
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Writes the record a finished call leaves in its DM, and fans it out live.
///
/// Best-effort on purpose: a call that happened is more important than its
/// record, and a store error here must not fail the request that ended the
/// ring. It is logged instead.
///
/// Every terminal outcome writes one, including `Answered` - the transcript is
/// the call history, so a call that did happen belongs in it as much as one
/// that did not. `duration_ms` is left null for now even on an answered call:
/// how long it lasted is only known when the last participant leaves, which is
/// the voice roster's business rather than the ring's, and filling it in is a
/// follow-up on top of this.
pub(crate) async fn record_call(
    state: &AppState,
    channel_id: ChannelId,
    ring_id: crate::ids::CallRingId,
    caller_id: crate::ids::UserId,
    outcome: CallRingOutcome,
) {
    state
        .push
        .notify_call_end(state.store.clone(), channel_id, ring_id, caller_id);
    let (sent, record) = match state
        .store
        .record_call(channel_id, caller_id, outcome.as_str(), None)
        .await
    {
        Ok(sent) => sent,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "failed to record a finished call");
            return;
        }
    };
    // A ring the caller gave up on is a missed call to the callee, as a timed-out one is.
    if outcome == CallRingOutcome::Canceled {
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id,
                author_id: caller_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: state.hub.presence(),
            },
        );
    }
    state.hub.publish(Event::MessageCreated {
        message: std::sync::Arc::new(sent.message),
        attachments: std::sync::Arc::new(Vec::new()),
        forwarded: None,
        app_surface: None,
        code_run: None,
        poll: None,
        embeds: std::sync::Arc::new(Vec::new()),
        call: Some(std::sync::Arc::new(record)),
        components: std::sync::Arc::new(Vec::new()),
    });
}
