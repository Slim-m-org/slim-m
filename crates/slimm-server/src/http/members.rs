// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moderating a member short of deleting their account: a timeout that lapses
//! on its own, and a removal that does not.
//!
//! Both are deployment-wide, so both gate on
//! [`crate::store::Store::base_permissions`] rather than on a channel, and
//! both use a permission bit that already existed and had never been spent:
//! KICK_MEMBERS for the temporary act (the voice-room eviction already reads
//! it as "put them out of where they are for now") and BAN_MEMBERS for the
//! durable one. That ladder is the whole authorization model here.
//!
//! On top of the bit, one rule stands in for the role hierarchy this product
//! does not have: you may only moderate somebody whose granted permissions
//! yours already contain. Without it, KICK_MEMBERS would be enough to silence
//! every administrator on the deployment one at a time. It is the same
//! no-escalation test [`super::roles`] applies when handing a role out, read
//! in the other direction, and it deliberately reads *granted* permissions so
//! that timing somebody out cannot itself be what makes them look junior
//! enough to time out again.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{delete, get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::escalation::escalation_guard;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use super::safety::validate_reason;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{
    DeleteAccountError, MAX_TIMEOUT_MS, RemoveMemberError, SpaceRemoval, TimeoutError, now_ms,
};
use crate::voice::VoiceError;

const BODY_LIMIT: usize = 4 * 1024;

/// The member moderation routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/members/{user_id}/timeout",
            put(apply_timeout).delete(lift_timeout),
        )
        .route(
            "/members/{user_id}/removal",
            put(remove_member).delete(restore_member),
        )
        .route("/members/removed", get(list_removed))
        .route("/members/{user_id}/account", delete(delete_member_account))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Deserialize)]
struct TimeoutRequest {
    /// How long from now, in seconds. The deadline is computed server-side so
    /// a client with a skewed clock cannot ask for one that has already
    /// passed, or for one decades out.
    duration_seconds: i64,
    reason: Option<String>,
}

#[derive(Serialize)]
struct TimeoutDto {
    user_id: String,
    until: i64,
}

#[derive(Deserialize)]
struct RemovalRequest {
    reason: Option<String>,
}

#[derive(Serialize)]
struct RemovalDto {
    user_id: String,
    username: String,
    display_name: String,
    reason: Option<String>,
    removed_by: Option<String>,
    removed_at: i64,
    /// The invite this member registered through, or `null` if they had
    /// none. This route already requires BAN_MEMBERS, so unlike
    /// `UserDto.invite_code` it is never gated further.
    invite_code: Option<String>,
}

impl From<SpaceRemoval> for RemovalDto {
    fn from(removal: SpaceRemoval) -> Self {
        Self {
            user_id: removal.user_id.to_string(),
            username: removal.username,
            display_name: removal.display_name,
            reason: removal.reason,
            removed_by: removal.removed_by.map(|id| id.to_string()),
            removed_at: removal.removed_at,
            invite_code: removal.invite_code,
        }
    }
}

impl From<TimeoutError> for ApiError {
    fn from(err: TimeoutError) -> Self {
        match err {
            TimeoutError::UserNotFound => ApiError::NotFound("no such member"),
            TimeoutError::Internal(err) => err.into(),
        }
    }
}

// --- Handlers ---

/// Times a member out for `duration_seconds`, replacing any timeout already
/// on them. Requires KICK_MEMBERS.
///
/// Evicts them from every voice room afterwards, because a LiveKit token is a
/// bearer credential this server cannot revoke: taking SPEAK away stops the
/// *next* token being useful and does nothing at all about the call they are
/// in right now. `voice.rs`'s own `kick` records the same thing. A failure to
/// reach the SFU is logged rather than failing the request - the timeout has
/// already committed, and reporting it as failed would invite a retry that
/// re-times-out somebody who is already timed out.
async fn apply_timeout(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<TimeoutRequest>,
) -> Result<Json<TimeoutDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    authorize(&state, ctx.user_id, target, Permissions::KICK_MEMBERS).await?;

    if req.duration_seconds <= 0 {
        return Err(ApiError::BadRequest("duration must be positive"));
    }
    let duration_ms = req
        .duration_seconds
        .checked_mul(1000)
        .filter(|ms| *ms <= MAX_TIMEOUT_MS)
        .ok_or(ApiError::BadRequest("duration is longer than 28 days"))?;
    let until = now_ms() + duration_ms;

    let reason = validate_reason(req.reason.as_deref(), false)?;
    let changed = state
        .store
        .set_member_timeout(target, until, reason.as_deref(), ctx.user_id)
        .await?;
    if changed {
        state.hub.publish(Event::MemberTimeoutChanged {
            user_id: target,
            until: Some(until),
        });
        evict_from_voice(&state, target).await;
    }

    Ok(Json(TimeoutDto {
        user_id: target.to_string(),
        until,
    }))
}

/// Lifts a timeout. Requires KICK_MEMBERS. Idempotent: lifting one that
/// already expired or never existed still leaves the member able to speak,
/// which is what the caller asked for.
async fn lift_timeout(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    authorize(&state, ctx.user_id, target, Permissions::KICK_MEMBERS).await?;

    if state
        .store
        .clear_member_timeout(target, ctx.user_id)
        .await?
    {
        state.hub.publish(Event::MemberTimeoutChanged {
            user_id: target,
            until: None,
        });
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Removes a member from the Space. Requires BAN_MEMBERS.
///
/// Everything they wrote stays and stays attributed to them; this revokes
/// access, and anonymizing content is what deleting an account does instead.
/// See the `space_removals` migration for why this has to be durable rather
/// than a one-off session revocation.
async fn remove_member(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<RemovalRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    authorize(&state, ctx.user_id, target, Permissions::BAN_MEMBERS).await?;

    let reason = validate_reason(req.reason.as_deref(), false)?;
    let revoked = match state
        .store
        .remove_from_space(target, ctx.user_id, reason.as_deref())
        .await
    {
        Ok(revoked) => revoked,
        Err(RemoveMemberError::UserNotFound) => return Err(ApiError::NotFound("no such member")),
        Err(RemoveMemberError::LastAdministrator) => {
            return Err(ApiError::Conflict(
                "the last administrator cannot be removed",
            ));
        }
        Err(RemoveMemberError::Internal(err)) => return Err(err.into()),
    };

    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    announce_member_gone(&state, target).await;
    Ok(StatusCode::NO_CONTENT)
}

/// What every way of a member leaving owes the rest of the deployment: a live
/// `MemberRemoved`, and eviction from voice, since a LiveKit token cannot be revoked.
pub(super) async fn announce_member_gone(state: &AppState, target: UserId) {
    state.hub.publish(Event::MemberRemoved(target));
    evict_from_voice(state, target).await;
}

/// Lets a removed member back in. Requires BAN_MEMBERS. 404 if they were not
/// removed, so a caller can tell an undo from a no-op.
async fn restore_member(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    require(&state, ctx.user_id, Permissions::BAN_MEMBERS).await?;

    if state.store.restore_to_space(target, ctx.user_id).await? {
        state.hub.publish(Event::MemberRestored(target));
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound("that member is not removed"))
    }
}

/// Deletes somebody else's account outright, the way they could delete their
/// own: personal data purged, authored content anonymized, the user
/// tombstoned, every session revoked, and the username freed for reuse.
///
/// Requires ADMINISTRATOR rather than BAN_MEMBERS, and deliberately so.
/// Removing a member takes their access away and is undone by
/// [`restore_member`]; this cannot be undone by anything. The two are not the
/// same power and must not share a permission.
///
/// Self-deletion keeps its own route (`DELETE /account`): a person deleting
/// their own account is not a moderation act, and routing it through here
/// would mean an administrator could not leave without another administrator
/// to do it for them.
///
/// The tombstone is what makes a removed account stop being listed:
/// [`Store::list_removals`] already skips deleted users, so nothing has to
/// clear the removal row, and the moderation record of it survives.
async fn delete_member_account(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    require(&state, ctx.user_id, Permissions::ADMINISTRATOR).await?;

    if target == ctx.user_id {
        return Err(ApiError::BadRequest(
            "delete your own account with DELETE /account",
        ));
    }

    let revoked = match state
        .store
        .delete_account_by_admin(target, ctx.user_id)
        .await
    {
        Ok(revoked) => revoked,
        Err(DeleteAccountError::WouldStrandDeployment) => {
            return Err(ApiError::Conflict(
                "that is the only administrator; appoint another before deleting it",
            ));
        }
        Err(DeleteAccountError::UserNotFound) => return Err(ApiError::NotFound("no such member")),
        Err(DeleteAccountError::Internal(e)) => return Err(e.into()),
    };
    for session_id in revoked {
        state.hub.publish(Event::SessionRevoked(session_id));
    }
    if let Err(err) = state.media.delete_avatar(&target.to_string()).await {
        tracing::warn!(error = %err, "failed to delete an account's avatar file");
    }
    announce_member_gone(&state, target).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Every removal in force. Requires BAN_MEMBERS, because this is the only
/// place a removed member is still nameable - the member list drops them.
///
/// The `invite_code` on each entry needs MANAGE_ROLES on top, for the reason
/// given on [`super::users::list`]: the code is redeemable for the role it
/// grants, so a caller who could not grant that role must not be able to read
/// one. The removal itself stays visible to any BAN_MEMBERS holder.
async fn list_removed(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
) -> Result<Json<Vec<RemovalDto>>, ApiError> {
    // AuthedRead, not Write: a plain list query, not a mutation.
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require(&state, ctx.user_id, Permissions::BAN_MEMBERS).await?;

    // Blanked below unless held; see the note in `http::users::list`.
    let sees_codes = state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_ROLES);
    let removals = state.store.list_removals().await?;
    Ok(Json(
        removals
            .into_iter()
            .map(|removal| {
                let mut dto = RemovalDto::from(removal);
                if !sees_codes {
                    dto.invite_code = None;
                }
                dto
            })
            .collect(),
    ))
}

// --- Guards ---

/// The caller holds `needed` deployment-wide.
pub(super) async fn require(
    state: &AppState,
    caller: UserId,
    needed: Permissions,
) -> Result<(), ApiError> {
    super::extract::require_base_permission(state, caller, needed)
        .await
        .map(drop)
}

/// [`require`], plus the two rules that apply when the act has a target: it
/// is not yourself, and you are not reaching above your own level.
///
/// Refusing self-moderation is not politeness. Timing yourself out would take
/// away the ability to lift it only if KICK_MEMBERS were among the masked
/// bits, which it is not - but removing yourself really would strand the
/// account, and one rule covering both is easier to keep true than two.
pub(super) async fn authorize(
    state: &AppState,
    caller: UserId,
    target: UserId,
    needed: Permissions,
) -> Result<(), ApiError> {
    if caller == target {
        return Err(ApiError::BadRequest("you cannot moderate yourself"));
    }
    require(state, caller, needed).await?;

    let caller_granted = state.store.granted_base_permissions(caller).await?;
    let target_granted = state.store.granted_base_permissions(target).await?;
    escalation_guard(caller_granted, target_granted)
}

/// Drops a member from every voice room they could currently be connected
/// to, best effort: every `voice`-kind channel, shared by the whole
/// deployment, plus every DM they are a party to. A DM call is a room the
/// same way a voice channel is - `store/dms.rs`'s own `DM_BASE` grants
/// `CONNECT` and `SPEAK` there - so this routine's whole reason to exist
/// (a LiveKit token is a bearer credential nothing else can revoke) applies
/// to it identically. It did not, until this fixed it: `evict_from_voice`
/// was written three days before a DM channel could hold a call at all, and
/// nothing revisited it once one could, so a removed or timed-out member
/// stayed on a DM call with a third party they had just lost every other
/// right to reach.
///
/// Best effort on purpose: the moderation act itself has already committed,
/// and there is nothing useful a caller could do with a failure here that
/// retrying the whole request would not do worse.
pub(super) async fn evict_from_voice(state: &AppState, target: UserId) {
    let Some(rooms) = voice_room_ids(state).await else {
        return;
    };
    evict_from_rooms(state, target, &rooms).await;
}

/// Every deployment-wide voice room, or `None` if they could not be listed.
///
/// Split from [`evict_from_voice`] so the bulk path reads this once for a
/// whole batch instead of once per member: the list is the same for all of
/// them, and re-reading it sixty-four times is sixty-three queries answering
/// a question already answered.
pub(super) async fn voice_room_ids(state: &AppState) -> Option<Vec<ChannelId>> {
    match state.store.list_channels().await {
        Ok(channels) => Some(
            channels
                .into_iter()
                .filter(|c| c.kind == "voice")
                .map(|c| c.id)
                .collect(),
        ),
        Err(err) => {
            tracing::warn!(%err, "could not list channels to evict a moderated member");
            None
        }
    }
}

/// Drops one member from [voice_rooms] and from every DM they are party to.
///
/// The DM half stays per member because it is per member; only the shared
/// voice rooms are hoisted.
pub(super) async fn evict_from_rooms(state: &AppState, target: UserId, voice_rooms: &[ChannelId]) {
    // Every DM, hidden ones included: see dm_channel_ids_for_user for why the sidebar list will not do.
    let dm_channel_ids = match state.store.dm_channel_ids_for_user(target).await {
        Ok(ids) => ids,
        Err(err) => {
            tracing::warn!(%err, "could not list a moderated member's DMs to evict them from");
            Vec::new()
        }
    };
    let rooms = voice_rooms.iter().copied().chain(dm_channel_ids);
    for channel_id in rooms {
        match state.voice.remove_participant(channel_id, target).await {
            // No SFU configured at all: there is no call to evict anyone from.
            Ok(()) | Err(VoiceError::Unavailable) => {}
            Err(VoiceError::Internal(err)) => {
                tracing::warn!(%err, "could not evict a moderated member from voice");
            }
        }
    }
}
