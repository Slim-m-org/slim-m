// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Joining a channel's voice room, and seeing who else already has. A minted
//! token is a credential the SFU trusts, so what a caller may do in a room is
//! decided here once; eviction makes a kick take effect before the token
//! lapses. See docs/internals.md for the heartbeat and roster reasoning.

use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::escalation::{escalation_guard, role_rank_guard};
use super::extract::{Authed, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::presence::Visibility;
use crate::ratelimit::Class;
use crate::voice::{CallRingOutcome, RoomToken, VoiceError};

pub(super) mod voice_calls;
pub(super) mod voice_move;
pub(super) mod voice_ring;
pub(super) mod voice_rooms;
pub(super) mod voice_webhook;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/voice/token", post(token))
        .route("/channels/{channel_id}/voice/roster", get(roster))
        .route(
            "/channels/{channel_id}/voice/heartbeat",
            post(heartbeat).delete(forget_heartbeat),
        )
        .route("/channels/{channel_id}/voice/deafened", put(set_deafened))
        .route(
            "/channels/{channel_id}/voice/participants/{user_id}/kick",
            post(kick),
        )
        .route(
            "/channels/{channel_id}/voice/participants/{user_id}/move",
            post(voice_move::move_participant),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct TokenResponse {
    url: String,
    room: String,
    token: String,
    expires_at: i64,
    can_publish: bool,
}

impl From<RoomToken> for TokenResponse {
    fn from(t: RoomToken) -> Self {
        Self {
            url: t.url,
            room: t.room,
            token: t.token,
            expires_at: t.expires_at,
            can_publish: t.can_publish,
        }
    }
}

/// Mints a short-lived join token for this channel's voice room.
///
/// `CONNECT` is the gate. `SPEAK` and `USE_CANVAS` are not checked here as
/// pass or fail: they are carried into the token as grants, so somebody with
/// listen-only rights gets in with a token that cannot publish, and the SFU
/// enforces that rather than the client being trusted to hide a button.
///
/// A nonexistent channel grants no permissions, so it refuses identically to a
/// channel the caller may not join, revealing neither.
///
/// Deliberately does not publish [`Event::VoiceActivityChanged`]: minting a
/// token is not joining, only being handed the credential to try. The first
/// heartbeat, sent once the client has actually connected to the SFU, is the
/// real signal; publishing here as well would notify for a token that is
/// never redeemed.
async fn token(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<TokenResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }

    if let Some(channel) = state.store.channel(channel_id).await? {
        self::voice_rooms::check_join(&state, &channel, ctx.user_id).await?;
    }

    // The token's name comes from the account, never from what the caller sends.
    let profile = state.store.user_profile(ctx.user_id).await?;
    let display_name = profile
        .as_ref()
        .map(|u| u.display_name.as_str())
        .unwrap_or("unknown");

    match state
        .voice
        .mint(channel_id, ctx.user_id, permissions, display_name)
    {
        Ok(token) => Ok(Json(token.into())),
        // No SFU is a supported configuration, not a fault; say so plainly.
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(
            "this server has no voice configured",
        )),
        Err(VoiceError::Internal(err)) => Err(err.into()),
    }
}

/// Refreshes proof that the caller is still on this channel's call, gated on
/// `CONNECT`. A first heartbeat is a join: it publishes the activity change
/// and answers a ring naming the caller, claiming the ring before recording
/// the heartbeat so the timeout sweep cannot also take it.
async fn heartbeat(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if !state.voice.is_enabled() {
        return Err(ApiError::NotConfigured(
            "this server has no voice configured",
        ));
    }

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }

    // Only a first join answers; see this function's own doc for both halves of why.
    let answered = if state.voice.has_heartbeat(ctx.user_id, channel_id) {
        None
    } else {
        state.voice.rings().answer(channel_id, ctx.user_id)
    };

    let is_a_real_join = state
        .voice
        .record_heartbeat_reporting_new(ctx.user_id, channel_id);
    if is_a_real_join {
        state
            .hub
            .publish(Event::VoiceActivityChanged { channel_id });
    }
    if let Some((ring_id, caller_id)) = answered {
        state.hub.publish(Event::CallRingEnded {
            channel_id,
            ring_id,
            outcome: CallRingOutcome::Answered,
        });
        self::voice_ring::record_call(
            &state,
            channel_id,
            ring_id,
            caller_id,
            CallRingOutcome::Answered,
        )
        .await;
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Drops the caller's heartbeat after a clean leave, so the sweep never calls
/// the SFU about someone already gone. Authentication only: forgetting your
/// own liveness exposes nothing, and a revoked permission must not block
/// cleanup. Also cancels a ring the caller started.
async fn forget_heartbeat(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let was_really_on_the_call = state
        .voice
        .forget_heartbeat_reporting_removed(ctx.user_id, channel_id);
    if was_really_on_the_call {
        state
            .hub
            .publish(Event::VoiceActivityChanged { channel_id });
        // A bot's watch session ends with its place on the call.
        super::watch_session::end_for_departed(&state, ctx.user_id, channel_id).await?;
    }
    // See this function's own doc for why this runs regardless of the above.
    if let Some(ring_id) = state.voice.rings().cancel(channel_id, ctx.user_id) {
        state.hub.publish(Event::CallRingEnded {
            channel_id,
            ring_id,
            outcome: CallRingOutcome::Canceled,
        });
        self::voice_ring::record_call(
            &state,
            channel_id,
            ring_id,
            ctx.user_id,
            CallRingOutcome::Canceled,
        )
        .await;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
struct RosterParticipantDto {
    user_id: String,
    display_name: String,
    is_sharing_screen: bool,
    has_video: bool,
}

#[derive(Serialize)]
struct RosterResponse {
    participants: Vec<RosterParticipantDto>,
    call_age_ms: Option<i64>,
}

/// Who is in a channel's voice room, gated on `VIEW_CHANNEL` like reading its
/// messages. Hidden participants are left out for everyone but themselves,
/// and `call_age_ms` is computed over the shown list so it cannot betray
/// one. An unreachable SFU answers 503, since that is not an empty room.
async fn roster(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<RosterResponse>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::Forbidden);
    }

    let connected = match state.voice.list_participants_shared(channel_id).await {
        Ok(list) => list,
        Err(VoiceError::Unavailable) => {
            return Err(ApiError::NotConfigured(
                "this server has no voice configured",
            ));
        }
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not list a channel's voice participants");
            return Err(ApiError::Unavailable);
        }
    };

    // One batched lookup rather than one per participant; see `Store::presence_visibility_many`.
    let other_ids: Vec<UserId> = connected
        .iter()
        .map(|p| p.user_id)
        .filter(|&id| id != ctx.user_id)
        .collect();
    let visibilities = state.store.presence_visibility_many(&other_ids).await?;

    let now = crate::store::now_ms();
    let mut earliest_join: Option<i64> = None;
    let mut participants = Vec::with_capacity(connected.len());
    for participant in connected {
        if participant.user_id != ctx.user_id
            && visibilities.get(&participant.user_id) == Some(&Visibility::Hidden)
        {
            continue;
        }
        earliest_join = match (earliest_join, participant.joined_at_ms) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        participants.push(RosterParticipantDto {
            user_id: participant.user_id.to_string(),
            display_name: participant.display_name,
            is_sharing_screen: participant.is_sharing_screen,
            has_video: participant.has_video,
        });
    }

    // An age rather than a start time, so a client with a skewed clock still reads the same call length.
    let call_age_ms = earliest_join.map(|joined| (now - joined).max(0));
    Ok(Json(RosterResponse {
        participants,
        call_age_ms,
    }))
}

#[derive(Deserialize)]
struct DeafenedRequest {
    deafened: bool,
}

/// Tells the room whether the caller has deafened themselves. Idempotent, and
/// a no-op when the caller is not in the room, since the SFU is the authority
/// on who is connected.
async fn set_deafened(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<DeafenedRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::CONNECT);
    if !permissions.contains(needed) {
        return Err(ApiError::Forbidden);
    }

    match state
        .voice
        .set_participant_deafened(channel_id, ctx.user_id, body.deafened)
        .await
    {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(
            "this server has no voice configured",
        )),
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not publish a participant's deafened state");
            Err(ApiError::Unavailable)
        }
    }
}

/// Evicts a participant from a channel's voice room, gated on `KICK_MEMBERS`
/// in that channel (so the escalation check compares channel-scoped grants)
/// and on outranking the target by role position, unless an administrator.
/// Idempotent, since the SFU is the authority on who is connected; taking
/// away `CONNECT` is what keeps them out afterwards.
async fn kick(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, user_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let target = UserId(parse_uuid(&user_id)?);

    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL.union(Permissions::KICK_MEMBERS)) {
        return Err(ApiError::Forbidden);
    }

    let caller_granted = state
        .store
        .granted_permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    let target_granted = state
        .store
        .granted_permissions_in_channel(target, channel_id)
        .await?;
    escalation_guard(caller_granted, target_granted)?;
    if ctx.user_id != target {
        let caller_is_admin = state
            .store
            .granted_base_permissions(ctx.user_id)
            .await?
            .contains(Permissions::ADMINISTRATOR);
        role_rank_guard(
            caller_is_admin,
            state.store.highest_role_position(ctx.user_id).await?,
            state.store.highest_role_position(target).await?,
        )?;
    }

    match state.voice.remove_participant(channel_id, target).await {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(VoiceError::Unavailable) => Err(ApiError::NotConfigured(
            "this server has no voice configured",
        )),
        // Unreachable SFU is a 503, not a 500; see the note on this function.
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not evict a voice participant");
            Err(ApiError::Unavailable)
        }
    }
}
