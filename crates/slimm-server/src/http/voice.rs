// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Joining a channel's voice room, and seeing who else already has.
//!
//! Most of these routes are almost entirely the check in front: the token
//! this hands back is a bearer credential the SFU trusts, so what a caller
//! may do in a room is decided here, once, from their permissions in that
//! channel.
//!
//! Eviction is the other half of that. A minted token cannot be revoked, so its
//! TTL bounds how long a removed participant could walk back in; removing them
//! from the room is what makes a kick take effect now rather than in two
//! minutes.
//!
//! The roster is read-only: `VIEW_CHANNEL` is the gate, the same bit
//! that lets a member read a text channel's messages without also being able
//! to send into it. A participant who chose to appear offline is dropped from
//! every viewer's roster but their own, the same treatment [`crate::presence`]
//! gives every other surface; see [`roster`]'s doc comment for why that is a
//! deliberate call rather than an oversight.
//!
//! The heartbeat pair is the exception to "the check in front": `heartbeat`
//! is gated the same way minting a token is, but `forget_heartbeat` is not
//! gated at all beyond authentication, because forgetting a caller's own
//! liveness marker exposes nothing about the channel it names.
//!
//! The heartbeat pair is also where [`Event::VoiceActivityChanged`] is
//! published: on the first heartbeat for a `(user, channel)` pair (a join)
//! and on a real forget (a clean hangup), each a single lock-held
//! check-and-write against [`crate::voice::VoiceService::record_heartbeat_reporting_new`]
//! / [`crate::voice::VoiceService::forget_heartbeat_reporting_removed`] so a
//! routine refresh never republishes and two concurrent first heartbeats
//! cannot both publish either. The third publish site, the stale-heartbeat
//! sweep, lives in `lib.rs` rather than here.

use axum::extract::DefaultBodyLimit;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::escalation::escalation_guard;
use super::extract::{Authed, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::presence::Visibility;
use crate::ratelimit::Class;
use crate::voice::{CallRingOutcome, RoomToken, VoiceError};

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
        .route(
            "/channels/{channel_id}/voice/participants/{user_id}/kick",
            post(kick),
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

/// Refreshes proof that the caller is still on this channel's call.
///
/// `CONNECT` is the gate, the same one minting a token requires: a heartbeat
/// for a room the caller could not have joined is not evidence of anything.
/// Best-effort by design on the client, and idempotent here - repeating it
/// only pushes the deadline out further. See [`crate::voice::VoiceService`]
/// for what a heartbeat that stops arriving eventually causes.
///
/// Publishes [`Event::VoiceActivityChanged`] only on a first heartbeat for
/// this `(user, channel)` pair - a real join - never on the routine refreshes
/// that follow it every few seconds for as long as the call lasts.
///
/// A FIRST join is also what answers an outstanding
/// [`crate::voice::CallRings`] ring naming this caller as the callee, since
/// nothing separate marks answering: joining a call *is* answering it. A
/// later keepalive from someone already in the room answers nothing. See
/// `voice::ring`'s own module doc for why answering has no route of its own.
///
/// The ring is claimed BEFORE the heartbeat is recorded, and the ordering is
/// load-bearing rather than incidental. `CallRings` and `CallHeartbeats` are
/// separately locked, so with the record first there was a window - a few
/// milliseconds against a 30-second timeout - in which
/// [`crate::sweep_stale_call_rings_at`] could take the ring between the two.
/// The callee ended up genuinely joined while the server published
/// `TimedOut` and evicted the CALLER, leaving one person alone in a room
/// with no `Answered` event ever sent. Claiming first makes the two outcomes
/// exclusive: either this takes the ring and the sweep finds nothing, or the
/// sweep took it first and this reads as an ordinary join, which is exactly
/// what it is by then.
///
/// [`crate::voice::VoiceService::has_heartbeat`] gates that claim, and it is
/// not redundant with the ordering above. Moving the claim ahead of the
/// record also moved it out from behind `is_a_real_join`, so without this
/// gate EVERY heartbeat would try to answer - including the routine 15-second
/// keepalives a call sends for as long as it lasts. A caller hanging up and
/// immediately calling back, while the callee is still sitting in the room,
/// would then have that second ring answered by the callee's own background
/// timer within 15 seconds, with the callee never seeing or touching it - and
/// an explicit Decline would be racing their own keepalive to the lock.
///
/// The read-then-write that gate opens is the one
/// [`crate::voice::VoiceService::has_heartbeat`]'s own doc warns about, but
/// it is harmless here: it decides only whether to ATTEMPT the claim, and
/// `CallRings::answer` is itself atomic, so two concurrent first heartbeats
/// can both attempt and exactly one can win. The publish that genuinely
/// needs the single lock-held check still uses
/// `record_heartbeat_reporting_new`, untouched.
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
        super::voice_ring::record_call(
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

/// Tells the server this caller left a channel's call cleanly, so its
/// heartbeat entry is dropped now rather than left for the sweep to
/// rediscover once it goes stale and call the SFU about a participant who
/// already disconnected on their own.
///
/// No permission gate beyond authentication, unlike every other route in this
/// file: forgetting one's own liveness marker cannot expose anything about a
/// channel, so there is nothing here for a permission check to protect and a
/// permission revoked mid-call must not be what blocks a client's own
/// cleanup. Harmless, and answers the same way, on a deployment with no SFU
/// configured or a channel that does not exist: there is never anything to
/// forget either way.
///
/// Publishes [`Event::VoiceActivityChanged`] only when there really was
/// something to forget, so a client that calls this having never joined (or
/// calling it twice) does not fan out a signal for a call that never changed.
///
/// Also cancels an outstanding ring naming this caller, independently of
/// whether a heartbeat existed to forget: a caller who rang but never got as
/// far as heartbeating yet can still hang up on the ring itself.
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
        super::voice_ring::record_call(
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

/// Who is currently connected to a channel's voice room, whether or not the
/// caller has joined it.
///
/// Gated on `VIEW_CHANNEL` alone, the same bit `listMessages` reads under:
/// seeing who is talking is exactly as sensitive as seeing what they typed,
/// and no more, so this does not also require `CONNECT`.
///
/// Appear-offline still applies here even though a room's own realtime
/// protocol has no such preference: a participant with [`Visibility::Hidden`]
/// is dropped from the roster of every viewer but themselves, structurally,
/// the same way [`crate::presence::status_for`] never lets a hidden user's
/// true state reach another viewer's payload. Joining a call with somebody
/// already still shows that person live once you are both in the room - the
/// SFU has to tell participants about each other to let them hear one
/// another - but this route is the *preview* shown before joining, and that
/// preview must not become a second way to learn a hidden user is online.
///
/// `call_age_ms` is how long the longest-present listed participant has been
/// in the room: the call's age, the same for everyone who can see them.
/// Computed over the filtered list only, so a hidden participant cannot be
/// inferred from an age older than anyone shown.
///
/// A configured SFU that cannot be reached answers 503, not 500 or an empty
/// list: an empty room and an unreachable one are different claims, and only
/// the former means nobody is there.
///
/// **Rate limit**: `Class::AuthedRead`, sized against this route's own real
/// cadence - `voiceRosterPollInterval` in the client polls it every 15
/// seconds per channel a rail row renders unjoined. It used to share
/// `Class::Write`'s budget with token mint, heartbeat, and kick, so a
/// deployment with more than a couple of open channels could exhaust that
/// budget on polling alone before any of those mutations ran. This still
/// makes one real call to the SFU's `ListParticipants` per request rather
/// than a plain row lookup, and unlike `/metrics` or `/space/analytics` it
/// is reachable by any member with `VIEW_CHANNEL`, not only an operator; see
/// [`Class::AuthedRead`]'s own doc for why that budget still holds here.
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

    let connected = match state.voice.list_participants(channel_id).await {
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

/// Evicts a participant from a channel's voice room.
///
/// Gated on `KICK_MEMBERS` in that channel, evaluated per channel rather than
/// deployment-wide, so a moderator's rights follow the same shape as every
/// other channel action here. That per-channel scope is why the escalation
/// check below reads `granted_permissions_in_channel` rather than
/// [`crate::store::Store::granted_base_permissions`]: a caller who holds
/// `KICK_MEMBERS` only through a channel overwrite may still hold nothing
/// deployment-wide, and comparing against the wrong scope would compare
/// against permissions that were never the ones granting this act. No
/// self-check, unlike [`super::members::authorize`]: kicking yourself out of
/// a room you are in is harmless, so nothing here refuses it.
///
/// Idempotent: removing somebody who is not in the room succeeds. The SFU is
/// the authority on who is connected, and a client that retries after a
/// timeout must not be told the kick failed when it landed.
///
/// This does not stop them asking for a new token. It is not meant to: taking
/// away `CONNECT` is what bars someone from a room, and this is what makes that
/// take effect immediately instead of whenever their current token lapses.
///
/// A configured SFU that cannot be reached answers 503, not 500: that is
/// upstream being down rather than this server malfunctioning, and it is the
/// difference a caller needs to decide whether retrying is worth anything.
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
