// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Invite routes: creating, listing, checking, and redeeming.
//!
//! Checking a code is unauthenticated, because it happens before someone has an
//! account, and rate limited (`Class::InviteCheck`) because it is. An unusable
//! code (expired, spent, revoked, or never issued) answers with exactly
//! `{"usable": false}`, byte for byte, so it cannot be used to mine valid
//! codes by telling them apart. A usable code additionally discloses what it
//! unlocks (the community's name and size, who invited the caller, and how
//! much of the code is left): reaching that branch already proves the caller
//! holds a working code, so it discloses nothing they had not already
//! demonstrated. See [`crate::store::InviteCheck`] for where that boundary is
//! enforced.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{
    AUTHED_READ, Authed, AuthedLimited, INVITE_CHECK, Json, RateLimited, WRITE, enforce,
};
use crate::hub::Event;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Invite, InviteCheck, RedeemError, now_ms};

const BODY_LIMIT: usize = 4 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/invites", get(list).post(create))
        .route("/invites/{code}", axum::routing::delete(revoke))
        .route("/invites/{code}/check", get(check))
        .route("/invites/{code}/redeem", post(redeem))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct InviteDto {
    code: String,
    max_uses: Option<i64>,
    uses: i64,
    expires_at: Option<i64>,
    created_at: i64,
    revoked: bool,
    usable: bool,
    /// The role this code grants, or null.
    role_grant: Option<String>,
    /// Who issued it; null when they are gone, and on a just-created invite.
    created_by_name: Option<String>,
}

fn dto(invite: Invite, now: i64) -> InviteDto {
    InviteDto {
        usable: invite.is_usable(now),
        role_grant: invite.role_grant.map(|id| id.to_string()),
        code: invite.code,
        max_uses: invite.max_uses,
        uses: invite.uses,
        expires_at: invite.expires_at,
        created_at: invite.created_at,
        revoked: invite.revoked,
        created_by_name: invite.created_by_name,
    }
}

#[derive(Deserialize)]
struct CreateRequest {
    /// Null means unlimited.
    max_uses: Option<i64>,
    /// Unix milliseconds; null means it never expires.
    expires_at: Option<i64>,
    /// A role every account redeeming this code receives. Null grants none.
    #[serde(default)]
    role_grant: Option<String>,
}

#[derive(Serialize)]
struct CheckResponse {
    /// Whether this code can be redeemed right now. Deliberately the only
    /// signal for an unusable code: saying *why* not would let someone probe
    /// for real codes.
    usable: bool,
    /// Present only when `usable` is true; see the module doc comment for
    /// why that boundary is the one that matters, not `skip_serializing_if`
    /// on the fields below it.
    #[serde(skip_serializing_if = "Option::is_none")]
    community: Option<InviteCommunity>,
}

#[derive(Serialize)]
struct InviteCommunity {
    /// This deployment's display name.
    name: String,
    /// How many live accounts the deployment has.
    member_count: i64,
    /// The inviter's current display name; null if their account has since
    /// been deleted.
    invited_by: Option<String>,
    /// Null means unlimited.
    uses_remaining: Option<i64>,
    /// Unix milliseconds; null means it never expires.
    expires_at: Option<i64>,
    /// The admin's short blurb; empty when none is set.
    description: String,
    /// When the banner was set, or null for none; fetch it from
    /// `/invites/{code}/banner`.
    banner_updated_at: Option<i64>,
    /// When the icon was set, or null for none; fetch it from
    /// `/invites/{code}/icon`.
    icon_updated_at: Option<i64>,
}

/// Resolves a requested role grant, refusing every way it could be an
/// escalation.
///
/// An invite that grants a role assigns that role to whoever redeems it, so it
/// is role assignment with a delay and must be gated exactly as `PUT
/// /members/{id}/roles/{id}` is: MANAGE_ROLES on top of CREATE_INVITE, and the
/// role's permissions already held by the caller. Without the second check,
/// CREATE_INVITE plus MANAGE_ROLES would mint an administrator account for
/// somebody holding neither bit.
async fn resolve_grant(
    state: &AppState,
    caller: crate::ids::UserId,
    raw: &str,
) -> Result<crate::ids::RoleId, ApiError> {
    let permissions = state.store.base_permissions(caller).await?;
    if !permissions.contains(Permissions::MANAGE_ROLES) {
        return Err(ApiError::Forbidden);
    }
    let role_id = crate::ids::RoleId(
        raw.parse::<uuid::Uuid>()
            .map_err(|_| ApiError::BadRequest("invalid role id"))?,
    );
    let role = state
        .store
        .role(role_id)
        .await?
        .ok_or(ApiError::NotFound("role not found"))?;
    if !permissions.contains(role.permissions) {
        return Err(ApiError::Forbidden);
    }
    Ok(role_id)
}

/// How a caller may invite: with the permission, or only as a member while
/// the space lets every member.
enum InviteAccess {
    Permitted,
    MemberOnly,
}

async fn invite_access(
    state: &AppState,
    user: crate::ids::UserId,
) -> Result<(InviteAccess, Permissions), ApiError> {
    let permissions = state.store.base_permissions(user).await?;
    if permissions.contains(Permissions::CREATE_INVITE) {
        return Ok((InviteAccess::Permitted, permissions));
    }
    let waiting = !matches!(
        state.store.member_gate(user).await?,
        crate::store::MemberGate::Member
    );
    if waiting {
        return Err(ApiError::Forbidden);
    }
    if state.store.members_can_invite().await? {
        return Ok((InviteAccess::MemberOnly, permissions));
    }
    Err(ApiError::Forbidden)
}

/// Whose invites a caller sees and revokes: everyone's only with both
/// CREATE_INVITE and MANAGE_ROLES, since another person's code is a credential.
/// Your own stay manageable whatever the switch says, so turning it off never
/// strands the codes you already made.
async fn invite_scope(
    state: &AppState,
    user: crate::ids::UserId,
) -> Result<Option<crate::ids::UserId>, ApiError> {
    let permissions = state.store.base_permissions(user).await?;
    let sees_all = permissions.contains(Permissions::CREATE_INVITE)
        && permissions.contains(Permissions::MANAGE_ROLES);
    Ok((!sees_all).then_some(user))
}

/// What a member without CREATE_INVITE gets when the request leaves it open,
/// and the most they may ask for.
const MEMBER_DEFAULT_USES: i64 = 1;
const MEMBER_DEFAULT_TTL_MS: i64 = 24 * 60 * 60 * 1000;
const MEMBER_MAX_USES: i64 = 10;
const MEMBER_MAX_TTL_MS: i64 = 7 * MEMBER_DEFAULT_TTL_MS;
const MEMBER_LIVE_INVITE_CAP: i64 = 20;

/// Creates an invite. Requires CREATE_INVITE, or any membership while the
/// space allows members to invite, in which case it is single-use and
/// short-lived unless the request asks for something within the member caps.
async fn create(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
    Json(req): Json<CreateRequest>,
) -> Result<Json<InviteDto>, ApiError> {
    let (access, _) = invite_access(&state, ctx.user_id).await?;
    let member_only = matches!(access, InviteAccess::MemberOnly);
    if req.max_uses.is_some_and(|max| max < 1) {
        return Err(ApiError::BadRequest("max_uses must be at least 1"));
    }
    let now = now_ms();
    if req.expires_at.is_some_and(|at| at <= now) {
        return Err(ApiError::BadRequest("expires_at must be in the future"));
    }
    let (max_uses, expires_at) = match access {
        InviteAccess::Permitted => (req.max_uses, req.expires_at),
        InviteAccess::MemberOnly => {
            if req.role_grant.is_some() {
                return Err(ApiError::Forbidden);
            }
            let max_uses = req.max_uses.unwrap_or(MEMBER_DEFAULT_USES);
            let expires_at = req.expires_at.unwrap_or(now + MEMBER_DEFAULT_TTL_MS);
            if max_uses > MEMBER_MAX_USES || expires_at > now + MEMBER_MAX_TTL_MS {
                return Err(ApiError::BadRequest(
                    "members can make invites of up to 10 uses and 7 days",
                ));
            }
            (Some(max_uses), Some(expires_at))
        }
    };

    let role_grant = match req.role_grant.as_deref() {
        None => None,
        Some(raw) => Some(resolve_grant(&state, ctx.user_id, raw).await?),
    };

    let invite = if member_only {
        state
            .store
            .create_invite_capped(ctx.user_id, max_uses, expires_at, MEMBER_LIVE_INVITE_CAP)
            .await?
            .ok_or(ApiError::BadRequest(
                "revoke an invite before making another",
            ))?
    } else {
        state
            .store
            .create_invite(ctx.user_id, role_grant, max_uses, expires_at)
            .await?
    };
    Ok(Json(dto(invite, now_ms())))
}

/// Every invite for MANAGE_ROLES, and only your own for anybody else who may
/// issue one.
///
/// CREATE_INVITE alone used to list the whole deployment's, which leaked a
/// credential: see [`Store::list_invites`] for why a code in somebody else's
/// row is one, and why MANAGE_ROLES is the bit that draws this line.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<InviteDto>>, ApiError> {
    let scope = invite_scope(&state, ctx.user_id).await?;
    let now = now_ms();
    let invites = state.store.list_invites(scope).await?;
    Ok(Json(invites.into_iter().map(|i| dto(i, now)).collect()))
}

/// Revokes an invite: anybody's for MANAGE_ROLES, your own otherwise.
///
/// A code the caller may not see answers 404 exactly as an unknown one does,
/// so somebody holding only CREATE_INVITE cannot probe for codes. Revoking a
/// code of theirs that is already revoked is a retry, and answers NO_CONTENT.
async fn revoke(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    let code = invite_code_key(&code);
    let scope = invite_scope(&state, ctx.user_id).await?;
    if state.store.revoke_invite(&code, scope).await? {
        return Ok(StatusCode::NO_CONTENT);
    }
    if state.store.invite_exists(&code, scope).await? {
        return Ok(StatusCode::NO_CONTENT);
    }
    Err(ApiError::NotFound("no such invite"))
}

/// Checks a code before signup. Unauthenticated by necessity: the person
/// holding it does not have an account yet. Rate limited because of that:
/// see the module doc comment for why a usable code is worth more to guess
/// for than before.
async fn check(
    _limited: RateLimited<INVITE_CHECK>,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CheckResponse>, ApiError> {
    match state.store.check_invite(&invite_code_key(&code)).await? {
        InviteCheck::Unusable => Ok(Json(CheckResponse {
            usable: false,
            community: None,
        })),
        InviteCheck::Usable(meta) => {
            let name = state.store.deployment_name().await?;
            let member_count = state.store.member_count().await?;
            let landing = state.store.space_landing().await?;
            Ok(Json(CheckResponse {
                usable: true,
                community: Some(InviteCommunity {
                    name,
                    member_count,
                    invited_by: meta.invited_by,
                    uses_remaining: meta.uses_remaining,
                    expires_at: meta.expires_at,
                    description: landing.description,
                    banner_updated_at: landing.banner_updated_at,
                    icon_updated_at: landing.icon_updated_at,
                }),
            }))
        }
    }
}

/// Spends an invite for the signed-in account. A fresh spend publishes
/// `Event::MemberJoined`; the idempotent already-redeemed retry does not, so a
/// greeter bot cannot be told the same join twice.
async fn redeem(
    Authed(ctx): Authed,
    parts: Parts,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    // Charged as a write: every attempt, hit or miss, opens the single-writer
    // transaction, so an unthrottled loop of garbage codes serialised the whole
    // server on the write lock while proving nothing.
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    match state
        .store
        .redeem_invite(&invite_code_key(&code), ctx.user_id)
        .await
    {
        Ok(freshly_redeemed) => {
            if freshly_redeemed {
                state.hub.publish(Event::MemberJoined(ctx.user_id));
                super::welcome::post_welcome(&state, ctx.user_id).await;
            }
            Ok(StatusCode::NO_CONTENT)
        }
        // One answer for expired, spent, revoked, and never-existed.
        Err(RedeemError::Unusable) => Err(ApiError::BadRequest("that invite cannot be used")),
        Err(RedeemError::Internal(e)) => Err(e.into()),
    }
}

/// Codes are generated lowercase and meant to be read aloud, so whatever case
/// the listener types back must still match.
pub(crate) fn invite_code_key(code: &str) -> String {
    code.trim().to_ascii_lowercase()
}
