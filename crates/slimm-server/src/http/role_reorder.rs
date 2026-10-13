// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting the deployment's role order: `PATCH /roles/reorder`.
//!
//! Gated on MANAGE_ROLES like every other route in `http::roles`, plus a
//! second guard that permission bit alone cannot express: a caller may only
//! touch a role whose old or new position sits strictly below the highest
//! position among roles they themselves hold - the position-hierarchy sibling
//! of [`escalation_guard`]'s bit comparison. Without it, a MANAGE_ROLES
//! holder with no elevated role of their own could drag `admin` above
//! `@everyone` in the list; the capability is purely cosmetic today (nothing
//! yet reads a "may I edit this role" answer off position), but the guard is
//! the one this feature needs before position starts meaning something a
//! caller could actually escalate with. An administrator bypasses it the same
//! way ADMINISTRATOR already contains every bit `escalation_guard` compares.

use std::collections::HashMap;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::patch;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_roles};
use super::messages::parse_uuid;
use super::roles::{RoleDto, caller_granted};
use crate::hub::Event;
use crate::ids::RoleId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::ReorderRolesError;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The role-ordering route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/roles/reorder", patch(reorder))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct ReorderRolesRequest {
    /// Every non-`@everyone` role id, top to bottom. Must be exactly the
    /// current set: no id may be missing, duplicated, unknown, or name
    /// `@everyone`, which never reorders.
    role_ids: Vec<String>,
}

/// The position [`crate::store::Store::reorder_roles`] would assign the role
/// at `index` of a request naming `total` roles - computed identically here
/// so the escalation guard below can be checked before that write runs.
fn position_for(total: usize, index: usize) -> i64 {
    total as i64 - index as i64
}

/// Sets the deployment's role order. Requires MANAGE_ROLES. Publishes
/// `RoleChanged` for every role the store reports actually moved, so a
/// no-op resubmission (the list unchanged) publishes nothing.
async fn reorder(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<ReorderRolesRequest>,
) -> Result<Json<Vec<RoleDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_roles(&state, ctx.user_id).await?;

    let ordered = req
        .role_ids
        .iter()
        .map(|id| parse_uuid(id).map(RoleId))
        .collect::<Result<Vec<_>, _>>()?;

    let granted = caller_granted(&state, ctx.user_id).await?;
    if !granted.contains(Permissions::ADMINISTRATOR) {
        let ceiling = state
            .store
            .highest_role_position(ctx.user_id)
            .await?
            .unwrap_or(0);
        let current: HashMap<RoleId, i64> = state
            .store
            .list_roles()
            .await?
            .into_iter()
            .filter(|r| !r.is_everyone)
            .map(|r| (r.id, r.position))
            .collect();
        let total = ordered.len();
        for (index, id) in ordered.iter().enumerate() {
            let new_position = position_for(total, index);
            let old_position = current.get(id).copied().unwrap_or(new_position);
            // The full live set is always required below, so a non-moving role must not trip this.
            if old_position == new_position {
                continue;
            }
            if old_position >= ceiling || new_position >= ceiling {
                return Err(ApiError::Forbidden);
            }
        }
    }

    match state.store.reorder_roles(&ordered).await {
        Ok(outcome) => {
            for role_id in &outcome.moved {
                state.hub.publish(Event::RoleChanged { role_id: *role_id });
            }
            let with_counts = state.store.list_roles_with_member_counts().await?;
            Ok(Json(with_counts.into_iter().map(RoleDto::from).collect()))
        }
        Err(ReorderRolesError::Mismatch { missing, extra }) => Err(ApiError::BadRequestDetail(
            mismatch_message(&missing, &extra),
        )),
        Err(ReorderRolesError::Internal(e)) => Err(e.into()),
    }
}

/// Names which roles a rejected order got wrong, mirroring
/// `http::channel_order::mismatch_message`'s identical shape for the same
/// reason: a partial list must never leave a gap unnamed.
fn mismatch_message(missing: &[RoleId], extra: &[RoleId]) -> String {
    let mut parts = Vec::new();
    if !missing.is_empty() {
        parts.push(format!("missing live role(s): {}", join_ids(missing)));
    }
    if !extra.is_empty() {
        parts.push(format!(
            "named unknown, repeated, or @everyone role(s): {}",
            join_ids(extra)
        ));
    }
    parts.join("; ")
}

fn join_ids(ids: &[RoleId]) -> String {
    ids.iter()
        .map(RoleId::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::position_for;

    /// The first id (top of the pane's list) gets the highest position, and
    /// the last gets 1 - never 0, so every reordered role always outranks
    /// `@everyone`'s bootstrap default.
    #[test]
    fn position_for_ranks_the_first_id_highest_and_never_reaches_zero() {
        assert_eq!(position_for(3, 0), 3);
        assert_eq!(position_for(3, 1), 2);
        assert_eq!(position_for(3, 2), 1);
    }
}
