// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel permission overwrites: set or clear the allow/deny pair for one
//! role or one member in one channel.
//!
//! Gated on MANAGE_ROLES *in this channel specifically* (via
//! [`crate::store::Store::permissions_in_channel`]), not the deployment-wide
//! check `http::roles` uses for role CRUD, because a channel overwrite can
//! itself grant or deny MANAGE_ROLES for that channel and the evaluator has
//! to be the one source of truth for what that resolves to. A nonexistent
//! channel grants nothing either way, so this refuses "no such channel" and
//! "not permitted here" identically, the same as every other channel-scoped
//! verb in this API.
//!
//! Only `allow` is checked against the caller's own effective permissions
//! before it is accepted: forcing a bit on is a grant, and a grant the caller
//! does not themselves hold is exactly the escalation this project treats as
//! a real vulnerability class. `deny` is a restriction, not a grant, and is
//! never gated on top of already requiring MANAGE_ROLES here.
//!
//! [`batch_set`] applies several targets' overwrites in one request rather
//! than one `PUT` per target: the permissions grid batches a pending set of
//! cell changes across several columns and wants to save them atomically, not
//! as a sequence of independent round trips a partial failure could leave
//! half-applied. Same checks as [`set`], run per entry before any of them
//! write.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, RoleId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::OverwriteBatchEntry;

/// A single-target request carries little more than two integers; a batch
/// carries one such pair per principal in the grid, so this stays generous
/// rather than tight the way the old single-target cap was.
const BODY_LIMIT: usize = 16 * 1024;

/// The channel overwrite routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/overwrites",
            get(list).put(batch_set),
        )
        .route(
            "/channels/{channel_id}/overwrites/{kind}/{id}",
            put(set).delete(clear),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// One overwrite on the wire: which role or member it targets and its
/// allow/deny bit pair.
#[derive(Serialize)]
pub(super) struct OverwriteDto {
    pub(super) kind: String,
    pub(super) id: String,
    pub(super) allow: i64,
    pub(super) deny: i64,
}

#[derive(Serialize)]
pub(super) struct OverwritesDto {
    pub(super) overwrites: Vec<OverwriteDto>,
    /// For a channel: whether its overwrites follow its category (decision 0064).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) synced: Option<bool>,
}

impl From<crate::store::ChannelOverwrite> for OverwriteDto {
    fn from(o: crate::store::ChannelOverwrite) -> Self {
        Self {
            kind: o.target_type,
            id: o.target_id.to_string(),
            allow: o.allow.bits(),
            deny: o.deny.bits(),
        }
    }
}

/// Lists every overwrite on a channel, so an editor sees the current
/// allow/deny pairs rather than rewriting one blind and silently re-granting
/// a deliberate denial. Gated on MANAGE_ROLES in this channel - the same
/// permission [`set`] and [`clear`] require, and the same refuse-identically
/// treatment of a channel the caller cannot manage or that does not exist.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OverwritesDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    require_manage_roles_here(&state, ctx.user_id, channel_id).await?;
    let overwrites = state
        .store
        .channel_overwrites(channel_id)
        .await?
        .into_iter()
        .map(|o| OverwriteDto {
            kind: o.target_type,
            id: o.target_id.to_string(),
            allow: o.allow.bits(),
            deny: o.deny.bits(),
        })
        .collect();
    let synced = state.store.channel_permissions_synced(channel_id).await?;
    Ok(Json(OverwritesDto { overwrites, synced }))
}

#[derive(Deserialize)]
struct SetOverwriteRequest {
    #[serde(default)]
    allow: i64,
    #[serde(default)]
    deny: i64,
}

/// What `{kind}/{id}` resolved to.
#[derive(Clone, Copy)]
pub(super) enum Target {
    Role(RoleId),
    Member(UserId),
}

pub(super) fn parse_target(kind: &str, id: &str) -> Result<Target, ApiError> {
    let id = parse_uuid(id)?;
    match kind {
        "role" => Ok(Target::Role(RoleId(id))),
        "member" => Ok(Target::Member(UserId(id))),
        _ => Err(ApiError::BadRequest("kind must be role or member")),
    }
}

/// Requires MANAGE_ROLES in this channel and returns the caller's effective
/// permissions there, reused by [`set`] as the ceiling on what it may grant.
async fn require_manage_roles_here(
    state: &AppState,
    user_id: UserId,
    channel_id: ChannelId,
) -> Result<Permissions, ApiError> {
    let permissions = state
        .store
        .permissions_in_channel(user_id, channel_id)
        .await?;
    if !permissions.contains(Permissions::MANAGE_ROLES) {
        return Err(ApiError::Forbidden);
    }
    Ok(permissions)
}

/// Refuses a write that hands out bits the caller lacks, naming them in the body.
pub(super) fn refuse_ungrantable(
    caller: Permissions,
    granted: Permissions,
) -> Result<(), ApiError> {
    let missing = granted.remove(caller);
    if missing == Permissions::NONE {
        Ok(())
    } else {
        Err(ApiError::MissingPermissions(missing))
    }
}

/// Refuses bits this server does not define, and a pair that both allows and
/// denies one bit: the evaluator would have to pick a winner silently.
pub(super) fn check_bits(allow: Permissions, deny: Permissions) -> Result<(), ApiError> {
    if !Permissions::ALL.contains(allow) || !Permissions::ALL.contains(deny) {
        return Err(ApiError::BadRequest("unknown permission bits"));
    }
    if allow.bits() & deny.bits() != 0 {
        return Err(ApiError::BadRequest(
            "allow and deny cannot both name the same permission",
        ));
    }
    Ok(())
}

/// Sets (or replaces) an overwrite. Rejects unknown permission bits outright,
/// and rejects any `allow` bit the caller does not themselves currently hold
/// in this channel.
///
/// "Grants" is not the same as the `allow` bits: clearing a `deny` hands out
/// that permission just as surely as setting an `allow` does. Judging by
/// `allow` alone let a caller who held MANAGE_ROLES but not, say,
/// MANAGE_SERVER strip an existing deny and give themselves the very bit they
/// could not have granted directly.
async fn set(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, kind, id)): Path<(String, String, String)>,
    State(state): State<AppState>,
    Json(req): Json<SetOverwriteRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller_permissions = require_manage_roles_here(&state, ctx.user_id, channel_id).await?;
    let target = parse_target(&kind, &id)?;

    let allow = Permissions::from_bits(req.allow);
    let deny = Permissions::from_bits(req.deny);
    check_bits(allow, deny)?;
    // Compares against what the write really grants, cleared denies included;
    // see the note on this function.
    let (target_type, target_id) = match target {
        Target::Role(role_id) => ("role", role_id.0),
        Target::Member(user_id) => ("member", user_id.0),
    };
    let (old_allow, old_deny) = state
        .store
        .overwrite_for(channel_id, target_type, target_id)
        .await?
        .unwrap_or((Permissions::NONE, Permissions::NONE));
    let granted = allow.remove(old_allow).union(old_deny.remove(deny));
    refuse_ungrantable(caller_permissions, granted)?;

    let previously_visible_to = previously_visible_to(&state, channel_id, target).await?;
    match target {
        Target::Role(role_id) => {
            if state.store.role(role_id).await?.is_none() {
                return Err(ApiError::NotFound("role not found"));
            }
            state
                .store
                .set_role_overwrite(channel_id, role_id, allow, deny)
                .await?;
        }
        Target::Member(user_id) => {
            if state.store.user_profile(user_id).await?.is_none() {
                return Err(ApiError::NotFound("user not found"));
            }
            state
                .store
                .set_member_overwrite(channel_id, user_id, allow, deny)
                .await?;
        }
    }
    state.hub.publish(Event::OverwriteChanged {
        channel_id,
        previously_visible_to,
    });
    Ok(StatusCode::NO_CONTENT)
}

/// One entry of a [`batch_set`] request: same shape as [`SetOverwriteRequest`]
/// with the target folded in, since a batch names several.
#[derive(Deserialize)]
pub(super) struct BatchOverwriteEntry {
    pub(super) kind: String,
    pub(super) id: String,
    #[serde(default)]
    pub(super) allow: i64,
    #[serde(default)]
    pub(super) deny: i64,
}

#[derive(Deserialize)]
pub(super) struct BatchSetRequest {
    pub(super) overwrites: Vec<BatchOverwriteEntry>,
}

/// A grid has one column per principal shown on a channel, and a deployment
/// with more than this many roles and members combined has bigger problems
/// than this cap; kept well inside [`BODY_LIMIT`] regardless.
pub(super) const MAX_BATCH_ENTRIES: usize = 64;

/// Applies every entry of [`BatchSetRequest::overwrites`] in one request:
/// the permissions grid's save button, batching a pending set of cell
/// changes across every column into one atomic write rather than one `PUT`
/// per changed target. Every entry is checked - unknown bits, target
/// existence, and the same escalation math [`set`] applies - before any of
/// them writes, so a batch either lands in full or is refused in full.
async fn batch_set(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<BatchSetRequest>,
) -> Result<Json<OverwritesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller_permissions = require_manage_roles_here(&state, ctx.user_id, channel_id).await?;

    if req.overwrites.len() > MAX_BATCH_ENTRIES {
        return Err(ApiError::BadRequest("too many overwrites in one batch"));
    }

    let mut named = std::collections::HashSet::new();
    let mut entries = Vec::with_capacity(req.overwrites.len());
    let mut targets = Vec::with_capacity(req.overwrites.len());
    for item in &req.overwrites {
        let target = parse_target(&item.kind, &item.id)?;
        let allow = Permissions::from_bits(item.allow);
        let deny = Permissions::from_bits(item.deny);
        check_bits(allow, deny)?;

        let (target_type, target_id): (&'static str, uuid::Uuid) = match target {
            Target::Role(role_id) => ("role", role_id.0),
            Target::Member(user_id) => ("member", user_id.0),
        };
        if !named.insert((target_type, target_id)) {
            return Err(ApiError::BadRequest(
                "a batch cannot name the same role or member more than once",
            ));
        }
        match target {
            Target::Role(role_id) if state.store.role(role_id).await?.is_none() => {
                return Err(ApiError::NotFound("role not found"));
            }
            Target::Member(user_id) if state.store.user_profile(user_id).await?.is_none() => {
                return Err(ApiError::NotFound("user not found"));
            }
            _ => {}
        }

        // Compares against what the write really grants, denies included; see `set`.
        let (old_allow, old_deny) = state
            .store
            .overwrite_for(channel_id, target_type, target_id)
            .await?
            .unwrap_or((Permissions::NONE, Permissions::NONE));
        let granted = allow.remove(old_allow).union(old_deny.remove(deny));
        refuse_ungrantable(caller_permissions, granted)?;

        targets.push(target);
        entries.push(OverwriteBatchEntry {
            target_type,
            target_id,
            allow,
            deny,
        });
    }

    // Resolved before the write, per target then deduplicated; see `previously_visible_to`.
    let mut previously_visible_to_all = Vec::new();
    for target in &targets {
        previously_visible_to_all.extend(previously_visible_to(&state, channel_id, *target).await?);
    }
    previously_visible_to_all.sort();
    previously_visible_to_all.dedup();

    state
        .store
        .set_channel_overwrites_batch(channel_id, &entries)
        .await?;
    state.hub.publish(Event::OverwriteChanged {
        channel_id,
        previously_visible_to: previously_visible_to_all,
    });

    let overwrites = state
        .store
        .channel_overwrites(channel_id)
        .await?
        .into_iter()
        .map(|o| OverwriteDto {
            kind: o.target_type,
            id: o.target_id.to_string(),
            allow: o.allow.bits(),
            deny: o.deny.bits(),
        })
        .collect();
    Ok(Json(OverwritesDto {
        overwrites,
        synced: Some(false),
    }))
}

/// Clears an overwrite. Idempotent: clearing one that is not set still
/// succeeds, so this needs no existence check on the target beyond the
/// channel itself.
///
/// Clearing an overwrite grants back every bit it was denying, so it needs the
/// same check setting one does; otherwise the guard on [`set`] is trivial to
/// walk around by deleting instead of rewriting.
async fn clear(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, kind, id)): Path<(String, String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller_permissions = require_manage_roles_here(&state, ctx.user_id, channel_id).await?;
    let target = parse_target(&kind, &id)?;

    // Checked against the bits being handed back; see the note on this
    // function.
    let (target_type, target_id) = match target {
        Target::Role(role_id) => ("role", role_id.0),
        Target::Member(user_id) => ("member", user_id.0),
    };
    if let Some((_, old_deny)) = state
        .store
        .overwrite_for(channel_id, target_type, target_id)
        .await?
    {
        refuse_ungrantable(caller_permissions, old_deny)?;
    }

    let previously_visible_to = previously_visible_to(&state, channel_id, target).await?;
    match target {
        Target::Role(role_id) => {
            state
                .store
                .delete_role_overwrite(channel_id, role_id)
                .await?
        }
        Target::Member(user_id) => {
            state
                .store
                .delete_member_overwrite(channel_id, user_id)
                .await?
        }
    }
    state.hub.publish(Event::OverwriteChanged {
        channel_id,
        previously_visible_to,
    });
    Ok(StatusCode::NO_CONTENT)
}

/// Who this overwrite affects and could already view the channel, resolved
/// before the write lands.
///
/// See [`Event::OverwriteChanged`] for why the event needs it: the ordinary
/// per-viewer check runs after the change, so the people whose access it just
/// removed are exactly the ones it would exclude.
pub(super) async fn previously_visible_to(
    state: &AppState,
    channel_id: ChannelId,
    target: Target,
) -> Result<Vec<UserId>, ApiError> {
    let affected = match target {
        Target::Member(user_id) => vec![user_id],
        Target::Role(role_id) => state.store.members_with_role(role_id).await?,
    };
    Ok(state.store.viewers_among(channel_id, &affected).await?)
}
