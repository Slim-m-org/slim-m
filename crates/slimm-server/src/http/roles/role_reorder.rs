// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting the deployment's role order: `PATCH /roles/reorder`. The roles at or above the caller's
//! highest stay where they are and every role moved stays below them; see [`super::super::role_ladder`].

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::patch;
use serde::Deserialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce, require_manage_roles};
use super::super::messages::parse_uuid;
use super::super::role_ladder::Ladder;
use super::RoleDto;
use crate::hub::Event;
use crate::ids::RoleId;
use crate::ratelimit::Class;
use crate::store::ReorderRolesError;

/// Every body here is a small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

/// The role-ordering route, mounted by [`super::super::router`].
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
    /// The order the client started from, top to bottom; a 409 when the live order moved since.
    #[serde(default)]
    expected_role_ids: Option<Vec<String>>,
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
    let expected = req
        .expected_role_ids
        .as_deref()
        .map(|ids| {
            ids.iter()
                .map(|id| parse_uuid(id).map(RoleId))
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()?;

    let ladder = Ladder::of(&state, ctx.user_id).await?;
    let caller = (!ladder.exempt()).then_some(ctx.user_id);
    let reordered = state
        .store
        .reorder_roles_below(&ordered, caller, expected.as_deref())
        .await;
    match reordered {
        Ok(outcome) => {
            for role_id in &outcome.moved {
                state.hub.publish(Event::RoleChanged {
                    role_id: *role_id,
                    change: None,
                });
            }
            let with_counts = state.store.list_roles_with_member_counts().await?;
            Ok(Json(with_counts.into_iter().map(RoleDto::from).collect()))
        }
        Err(ReorderRolesError::Mismatch { missing, extra }) => Err(ApiError::BadRequestDetail(
            mismatch_message(&missing, &extra),
        )),
        Err(ReorderRolesError::AboveCaller) => Err(ladder.role_out_of_reach()),
        Err(ReorderRolesError::Stale) => Err(ApiError::Conflict(
            "the role order changed since you loaded it",
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
