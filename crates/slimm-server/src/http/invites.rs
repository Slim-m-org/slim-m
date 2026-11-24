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
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{
    AUTHED_READ, Authed, AuthedLimited, INVITE_CHECK, Json, RateLimited, WRITE, enforce,
    require_manage_roles,
};
use super::participant::Participant;
use super::role_ladder::{Ladder, hand_assignable};
use crate::hub::Event;
use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{GrantReach, Invite, InviteCheck, InviteScope, RedeemError, now_ms};

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
    /// Return the caller's live invite with these limits instead of minting
    /// another; the "invite a friend" button sets it so a repeated click shares one code.
    #[serde(default)]
    reuse: bool,
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
/// /members/{id}/roles/{id}` is: MANAGE_ROLES on top of CREATE_INVITE, the
/// role below the caller's own on the role ladder, and its permissions already
/// held by the caller. Without the bit check, CREATE_INVITE plus MANAGE_ROLES
/// would mint an administrator account for somebody holding neither bit.
async fn resolve_grant(state: &AppState, caller: UserId, raw: &str) -> Result<RoleId, ApiError> {
    let permissions = require_manage_roles(state, caller).await?;
    let role_id = RoleId(
        raw.parse::<uuid::Uuid>()
            .map_err(|_| ApiError::BadRequest("invalid role id"))?,
    );
    let role = state
        .store
        .role(role_id)
        .await?
        .ok_or(ApiError::NotFound("role not found"))?;
    hand_assignable(&role)?;
    Ladder::of(state, caller).await?.reach_role(role.position)?;
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
    user: UserId,
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

/// The caller's base permissions when they may manage roles, two-factor policy included.
async fn role_manager(state: &AppState, user: UserId) -> Result<Option<Permissions>, ApiError> {
    match require_manage_roles(state, user).await {
        Ok(permissions) => Ok(Some(permissions)),
        Err(ApiError::Forbidden | ApiError::ForbiddenBecause(_)) => Ok(None),
        Err(err) => Err(err),
    }
}

/// Whose invites a caller sees and revokes: everyone's only with both CREATE_INVITE and MANAGE_ROLES, since another person's code is a credential.
/// Your own stay manageable whatever the switch says, so turning it off never strands codes you made.
/// Below the owner, another person's code that grants a role shows only to a manager who could grant that role by hand, as [`resolve_grant`] checks.
async fn invite_scope(state: &AppState, user: UserId) -> Result<InviteScope, ApiError> {
    let own = InviteScope {
        creator: Some(user),
        grants: None,
    };
    let Some(permissions) = role_manager(state, user).await? else {
        return Ok(own);
    };
    if !permissions.contains(Permissions::CREATE_INVITE) {
        return Ok(own);
    }
    let ladder = Ladder::of(state, user).await?;
    let grants = (!ladder.exempt()).then(|| GrantReach {
        manager: user,
        below: ladder.top().unwrap_or(i64::MIN),
        holds: permissions,
    });
    Ok(InviteScope {
        creator: None,
        grants,
    })
}

/// Which registration codes a caller may read off a member row: none without MANAGE_ROLES,
/// otherwise only those `GET /invites` would show them, since a code is redeemable for its role.
pub(super) async fn code_reader_scope(
    state: &AppState,
    user: UserId,
) -> Result<Option<InviteScope>, ApiError> {
    if role_manager(state, user).await?.is_none() {
        return Ok(None);
    }
    invite_scope(state, user).await.map(Some)
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
/// A timed-out caller makes none, or a timeout could be sat out on a fresh account.
async fn create(
    Participant(ctx): Participant<WRITE>,
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

    let invite = if req.reuse && role_grant.is_none() {
        let cap = if member_only {
            MEMBER_LIVE_INVITE_CAP
        } else {
            i64::MAX
        };
        state
            .store
            .live_or_new_invite(ctx.user_id, max_uses, expires_at, cap)
            .await?
            .ok_or(ApiError::BadRequest(
                "revoke an invite before making another",
            ))?
    } else if member_only {
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

const DEFAULT_PAGE: i64 = 50;
const MAX_PAGE: i64 = 100;

#[derive(Deserialize)]
struct ListQuery {
    limit: Option<i64>,
    /// The code of the last invite of the previous page.
    before: Option<String>,
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
    Query(page): Query<ListQuery>,
) -> Result<Json<Vec<InviteDto>>, ApiError> {
    let scope = invite_scope(&state, ctx.user_id).await?;
    let now = now_ms();
    let limit = page.limit.unwrap_or(DEFAULT_PAGE).clamp(1, MAX_PAGE);
    let invites = state
        .store
        .list_invites(scope, page.before.as_deref(), limit)
        .await?;
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
/// `Event::MemberJoined`, and `Event::MemberRoleChanged` for a role it gave; the idempotent
/// already-redeemed retry publishes neither, so a greeter bot cannot be told the same join twice.
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
    let code = invite_code_key(&code);
    match state.store.redeem_invite(&code, ctx.user_id).await {
        Ok(redemption) => {
            if redemption.fresh {
                state.hub.publish(Event::MemberJoined(ctx.user_id));
                if let Some(role_id) = redemption.granted {
                    announce_role_granted(&state, ctx.user_id, role_id).await;
                }
                super::welcome::post_welcome(&state, ctx.user_id).await;
            }
            Ok(StatusCode::NO_CONTENT)
        }
        // One answer for expired, spent, revoked, and never-existed.
        Err(RedeemError::Unusable) => Err(ApiError::BadRequest("that invite cannot be used")),
        Err(RedeemError::Internal(e)) => Err(e.into()),
    }
}

/// Tells the member's other devices about the role, so they refetch the channels it opens.
/// The redemption has committed, so a failed name lookup still announces, without the name.
async fn announce_role_granted(state: &AppState, user_id: UserId, role_id: RoleId) {
    let role_name = match state.store.role(role_id).await {
        Ok(role) => role.map(|role| role.name),
        Err(err) => {
            tracing::warn!(error = %err, %role_id, "could not name the role an invite gave");
            None
        }
    };
    state.hub.publish(Event::MemberRoleChanged {
        user_id,
        role_id,
        granted: true,
        role_name,
    });
}

/// Codes are generated lowercase and meant to be read aloud, so whatever case
/// the listener types back must still match.
pub(crate) fn invite_code_key(code: &str) -> String {
    code.trim().to_ascii_lowercase()
}
