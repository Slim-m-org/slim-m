// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Role management: create, list, update, and delete roles, and grant or
//! revoke one on a member. Every verb here is gated on MANAGE_ROLES at the
//! deployment level, since roles are not scoped to any one channel.
//!
//! This is one of the highest-privilege surfaces in the product, so two
//! guards apply everywhere a permission set becomes grantable (creating a
//! role, changing one's permissions, or assigning an existing role to a
//! member): the bits involved must already be held by the caller, or holding
//! MANAGE_ROLES would be enough to hand out permissions nobody approved for
//! you to hand out, ADMINISTRATOR included. The other guard, that the
//! deployment always keeps at least one administrator, lives in
//! [`crate::store::roles`] because it has to see every caller at once, not
//! just this request's.
//!
//! A role is also revocable, patchable and deletable, and those three used to
//! carry none of the above: a MANAGE_ROLES holder could strip ADMINISTRATOR
//! from a role no `grantable` check ever ran against, because nothing looked
//! at what the role already held before the write, only at what the request
//! asked for. `unassign` is phrased symmetrically with `assign` - the same
//! [`super::escalation::escalation_guard`] call, before revoking rather than
//! granting - and `update`/`delete` run it against the role's own current
//! bits, since a role has no user to check instead.
//!
//! A bot is a role holder like any other; see
//! `docs/decisions/0028-bot-accounts.md`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::escalation::escalation_guard;
use super::extract::require_manage_roles;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::hidden_chars::is_hidden_char;
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{ROLE_COLOR_COUNT, Role, RoleChanges, RoleGuardError, RoleWithCount};

const BODY_LIMIT: usize = 4 * 1024;

/// The role management routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/roles", get(list).post(create))
        .route("/roles/{role_id}", patch(update).delete(delete))
        .route(
            "/members/{user_id}/roles/{role_id}",
            put(assign).delete(unassign),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

/// `pub(super)`: [`super::role_reorder`] returns this same shape from its own
/// endpoint, and reuses [`RoleWithCount`]'s conversion below to build it.
#[derive(Serialize)]
pub(super) struct RoleDto {
    id: String,
    name: String,
    /// The raw permission bitmask; see `crate::permissions::Permissions` for
    /// what each bit means.
    permissions: i64,
    is_everyone: bool,
    /// Whether any member may wake this role with `@[Role Name]` with no
    /// permission of their own; see `crate::store::Role::mentionable`.
    mentionable: bool,
    /// Whether the member pane lists this role's members under their own heading.
    hoist: bool,
    /// An index into the client's role palette, or null for the colour derived from the id.
    color: Option<i64>,
    created_at: i64,
    /// See [`Role::managed_bot_id`].
    managed_bot_id: Option<String>,
    /// Hierarchy order: higher sorts first, matching the order this list
    /// already comes back in. `@everyone` always sits last; see
    /// [`Role::position`].
    position: i64,
    /// How many members currently hold this role; `@everyone`'s reads the
    /// whole deployment's member count. See
    /// [`crate::store::Store::list_roles_with_member_counts`].
    member_count: i64,
}

impl RoleDto {
    fn new(role: Role, member_count: i64) -> Self {
        Self {
            id: role.id.to_string(),
            name: role.name,
            permissions: role.permissions.bits(),
            is_everyone: role.is_everyone,
            mentionable: role.mentionable,
            hoist: role.hoist,
            color: role.color,
            created_at: role.created_at,
            managed_bot_id: role.managed_bot_id.map(|id| id.to_string()),
            position: role.position,
            member_count,
        }
    }
}

impl From<RoleWithCount> for RoleDto {
    fn from(with_count: RoleWithCount) -> Self {
        RoleDto::new(with_count.role, with_count.member_count)
    }
}

#[derive(Deserialize)]
struct CreateRoleRequest {
    /// Client-generated UUIDv7 that makes the create idempotent on retry.
    /// Absent means the server mints one and this is always a fresh create.
    id: Option<String>,
    name: String,
    permissions: i64,
    /// Defaults false, applied only on a genuinely fresh create; see
    /// [`create`].
    mentionable: Option<bool>,
}

#[derive(Deserialize)]
struct UpdateRoleRequest {
    name: Option<String>,
    permissions: Option<i64>,
    mentionable: Option<bool>,
    hoist: Option<bool>,
    color: Option<i64>,
}

// --- Handlers: role CRUD ---

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<RoleDto>>, ApiError> {
    require_manage_roles(&state, ctx.user_id).await?;
    let roles = state.store.list_roles_with_member_counts().await?;
    Ok(Json(roles.into_iter().map(RoleDto::from).collect()))
}

/// Creates a role. `mentionable` always starts false at the store layer
/// (`Store::create_role_with_id` takes no such parameter); when the request
/// asks for `true` on a genuinely fresh create, this makes a second write to
/// set it, so a retry of an already-succeeded create never reapplies it.
async fn create(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<CreateRoleRequest>,
) -> Result<Json<RoleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let caller_permissions = require_manage_roles(&state, ctx.user_id).await?;

    let name = validate_role_name(&req.name)?;
    let permissions = grantable(caller_permissions, req.permissions)?;
    let id = req
        .id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(RoleId))
        .transpose()?
        .unwrap_or_else(RoleId::generate);

    // Never `@everyone`: exactly one exists, seeded only by
    // `Store::bootstrap_deployment`, and this endpoint cannot ask for it.
    let created = state
        .store
        .create_role_with_id(id, name, permissions, false)
        .await?;
    // See this function's own doc comment for why this is a second write.
    if created.fresh && req.mentionable.unwrap_or(false) {
        state
            .store
            .update_role(
                created.id,
                RoleChanges {
                    mentionable: Some(true),
                    ..RoleChanges::default()
                },
            )
            .await
            .map_err(role_guard_error)?;
    }
    let role = state
        .store
        .role(created.id)
        .await?
        .ok_or(ApiError::Internal)?;
    // An idempotent retry must not fan out again; see the note on `CreatedRole::fresh`.
    if created.fresh {
        state.hub.publish(Event::RoleChanged {
            role_id: created.id,
        });
    }
    // A role this endpoint just created has no holders yet; see the doc above.
    Ok(Json(RoleDto::new(role, 0)))
}

async fn update(
    Authed(ctx): Authed,
    parts: Parts,
    Path(role_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<UpdateRoleRequest>,
) -> Result<Json<RoleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let caller_permissions = require_manage_roles(&state, ctx.user_id).await?;
    let role_id = RoleId(parse_uuid(&role_id)?);

    let name = req.name.as_deref().map(validate_role_name).transpose()?;
    let permissions = req
        .permissions
        .map(|bits| grantable(caller_permissions, bits))
        .transpose()?;
    let color = req.color.map(validate_role_color).transpose()?;
    let changes = RoleChanges {
        name,
        permissions,
        mentionable: req.mentionable,
        hoist: req.hoist,
        color,
    };
    if changes.is_empty() {
        return Err(ApiError::BadRequest("nothing to update"));
    }

    // Read before the write, against granted permissions; see `escalation`.
    if let Some(current) = state.store.role(role_id).await? {
        escalation_guard(
            caller_granted(&state, ctx.user_id).await?,
            current.permissions,
        )?;
    }

    // Hoist and colour cannot remove an administrator, so they need no guard of their own.
    let updated = state.store.update_role(role_id, changes).await;
    match updated {
        Ok(Some(role)) => {
            let role = state.store.role(role.id).await?.ok_or(ApiError::Internal)?;
            state.hub.publish(Event::RoleChanged { role_id });
            let member_count = state.store.member_count_for_role(&role).await?;
            Ok(Json(RoleDto::new(role, member_count)))
        }
        Ok(None) => Err(ApiError::NotFound("role not found")),
        Err(guard_err) => Err(role_guard_error(guard_err)),
    }
}

/// Deletes a role. Refuses `@everyone` and refuses to take the deployment
/// below one administrator; both come back as 409, since either way the
/// request collided with an invariant rather than a permission the caller
/// simply lacks.
async fn delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path(role_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_roles(&state, ctx.user_id).await?;
    let role_id = RoleId(parse_uuid(&role_id)?);

    // Read before the mutating write; see `update`'s identical note.
    if let Some(current) = state.store.role(role_id).await? {
        escalation_guard(
            caller_granted(&state, ctx.user_id).await?,
            current.permissions,
        )?;
    }

    match state.store.delete_role(role_id).await {
        Ok(Some(())) => {
            state.hub.publish(Event::RoleChanged { role_id });
            Ok(StatusCode::NO_CONTENT)
        }
        Ok(None) => Err(ApiError::NotFound("role not found")),
        Err(guard_err) => Err(role_guard_error(guard_err)),
    }
}

// --- Handlers: member role assignment ---

/// Grants a role to a member. Idempotent. Refused if the role carries a
/// permission the caller does not themselves hold, since granting a role is
/// granting whatever it carries.
async fn assign(
    Authed(ctx): Authed,
    parts: Parts,
    Path((user_id, role_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_roles(&state, ctx.user_id).await?;
    let user_id = UserId(parse_uuid(&user_id)?);
    let role_id = RoleId(parse_uuid(&role_id)?);

    let role = state
        .store
        .role(role_id)
        .await?
        .ok_or(ApiError::NotFound("role not found"))?;
    escalation_guard(caller_granted(&state, ctx.user_id).await?, role.permissions)?;

    if state.store.assign_role(user_id, role_id).await? {
        state
            .hub
            .publish(Event::MemberRoleChanged { user_id, role_id });
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Revokes a role from a member. Idempotent, and refused if it would leave
/// the deployment with no administrator.
///
/// Phrased symmetrically with [`assign`]: the same guard, against the same
/// role bits, before revoking rather than granting. A missing role skips the
/// check rather than 404ing, matching this route's existing idempotency -
/// there is nothing to revoke and so nothing to escalate.
async fn unassign(
    Authed(ctx): Authed,
    parts: Parts,
    Path((user_id, role_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_roles(&state, ctx.user_id).await?;
    let user_id = UserId(parse_uuid(&user_id)?);
    let role_id = RoleId(parse_uuid(&role_id)?);

    if let Some(role) = state.store.role(role_id).await? {
        escalation_guard(caller_granted(&state, ctx.user_id).await?, role.permissions)?;
    }

    match state.store.unassign_role(user_id, role_id).await {
        Ok(removed) => {
            if removed {
                state
                    .hub
                    .publish(Event::MemberRoleChanged { user_id, role_id });
            }
            Ok(StatusCode::NO_CONTENT)
        }
        Err(guard_err) => Err(role_guard_error(guard_err)),
    }
}

// --- Shared checks ---

/// Requires MANAGE_ROLES at the deployment level and returns the caller's
/// full base permission set, so `grantable` can reuse it without a second
/// lookup.
///
/// This is the *effective* set, which is what a verb gate wants: a moderator
/// under a subtraction should not be managing roles while it is in force.
/// The level comparison is a different question and reads
/// [`caller_granted`] instead - the same split
/// [`super::members::authorize`] makes, and for the same reason.
/// The caller's granted (unmasked) permissions, for
/// [`escalation_guard`]'s side of the comparison only.
///
/// Separate from [`require_manage_roles`] deliberately, so the two questions
/// stay two questions: whether the caller may act at all is effective, and
/// whether they may act on *this* is granted. Reading the effective set here
/// would be identical today, since nothing in `TIMEOUT_DENY` touches a
/// role-management bit - and would silently become a hole the moment something
/// did.
///
/// `pub(super)`: [`super::role_reorder`] reuses this for its own
/// position-hierarchy guard's administrator bypass.
pub(super) async fn caller_granted(
    state: &AppState,
    user_id: UserId,
) -> Result<Permissions, ApiError> {
    Ok(state.store.granted_base_permissions(user_id).await?)
}

/// Validates that `bits` names only defined permissions and that every one of
/// them is already held by `caller`, so MANAGE_ROLES alone can never be used
/// to hand out a permission the caller lacks. An administrator's `caller`
/// already resolves to [`Permissions::ALL`], so this is also where that
/// bypass takes effect.
///
/// `pub(super)`: [`super::bots`] reuses this for a bot's managed role.
pub(super) fn grantable(caller: Permissions, bits: i64) -> Result<Permissions, ApiError> {
    let requested = Permissions::from_bits(bits);
    if !Permissions::ALL.contains(requested) {
        return Err(ApiError::BadRequest("unknown permission bits"));
    }
    if !caller.contains(requested) {
        return Err(ApiError::Forbidden);
    }
    Ok(requested)
}

fn role_guard_error(err: RoleGuardError) -> ApiError {
    match err {
        RoleGuardError::IsEveryone => ApiError::Conflict("the @everyone role cannot be deleted"),
        RoleGuardError::LastAdministrator => {
            ApiError::Conflict("this would leave the deployment with no administrator")
        }
        RoleGuardError::Internal(e) => e.into(),
    }
}

fn validate_role_name(name: &str) -> Result<&str, ApiError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > crate::limits::MAX_NAME_CHARS {
        return Err(ApiError::BadRequest("name must be 1 to 64 characters"));
    }
    if trimmed.chars().any(is_hidden_char) {
        return Err(ApiError::BadRequest(
            "name must not contain control or invisible characters",
        ));
    }
    Ok(trimmed)
}

fn validate_role_color(color: i64) -> Result<i64, ApiError> {
    if usize::try_from(color).is_ok_and(|index| index < ROLE_COLOR_COUNT) {
        Ok(color)
    } else {
        Err(ApiError::BadRequest(
            "color must be a palette index from 0 to 9",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_caller_may_grant_a_subset_of_their_own_permissions() {
        let caller = Permissions::MANAGE_ROLES.union(Permissions::SEND_MESSAGES);
        let result = grantable(caller, Permissions::SEND_MESSAGES.bits());
        assert!(matches!(result, Ok(p) if p == Permissions::SEND_MESSAGES));
    }

    /// A caller cannot grant a permission they do not themselves hold - the
    /// check that stops a role editor minting themselves, or anyone else, more
    /// than they have.
    #[test]
    fn a_caller_cannot_grant_a_permission_they_lack() {
        let result = grantable(
            Permissions::SEND_MESSAGES,
            Permissions::MANAGE_MESSAGES.bits(),
        );
        assert!(matches!(result, Err(ApiError::Forbidden)));
    }

    /// Unknown bits are refused before the caller check, so even an all-powerful
    /// caller cannot grant a permission the server does not define.
    #[test]
    fn unknown_permission_bits_are_refused_even_for_a_full_caller() {
        let undefined = 1i64 << 20;
        let result = grantable(Permissions::ALL, undefined);
        assert!(matches!(result, Err(ApiError::BadRequest(_))));
    }
}
