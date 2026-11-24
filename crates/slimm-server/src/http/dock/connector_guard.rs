// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may install, update or re-key a connector: a caller who holds everything it was approved
//! and outranks its principal, as `POST /bots` and `POST /bots/{id}/token` require for a bot.

use super::super::AppState;
use super::super::error::ApiError;
use super::super::escalation::escalation_guard;
use super::super::role_ladder::Ladder;
use crate::hub::Event;
use crate::ids::{RoleId, UserId};
use crate::permissions::Permissions;
use crate::store::InstalledModule;

/// Refuses unless `caller` holds the connector's whole approved ceiling and ranks above its principal.
pub(super) async fn guard_over_connector(
    state: &AppState,
    caller: UserId,
    connector: &InstalledModule,
) -> Result<(), ApiError> {
    let (Some(principal), Some(ceiling)) = (connector.bot_user_id, connector.connector_permissions)
    else {
        return Ok(());
    };
    escalation_guard(state.store.base_permissions(caller).await?, ceiling)?;
    Ladder::of(state, caller)
        .await?
        .reach_member(state, principal)
        .await
}

/// Refuses unless `caller` may hand a new principal the shared Bots role, as `POST /bots` does.
pub(super) async fn guard_new_principal(state: &AppState, caller: UserId) -> Result<(), ApiError> {
    let shared = state
        .store
        .list_roles()
        .await?
        .into_iter()
        .find(|role| role.is_bots_role);
    Ladder::of(state, caller)
        .await?
        .reach_role(shared.as_ref().map_or(0, |role| role.position.max(0)))?;
    escalation_guard(
        state.store.base_permissions(caller).await?,
        shared.map_or(Permissions::NONE, |role| role.permissions),
    )
}

/// The role a connector's principal holds on its own, if it has one.
pub(super) async fn managed_role(
    state: &AppState,
    principal: Option<UserId>,
) -> Result<Option<RoleId>, ApiError> {
    let Some(principal) = principal else {
        return Ok(None);
    };
    Ok(state.store.role_for_bot(principal).await?.map(|r| r.id))
}

/// Tells live sockets and role lists that these roles' grants moved.
pub(super) fn announce_roles_changed(state: &AppState, roles: impl IntoIterator<Item = RoleId>) {
    let mut seen = Vec::new();
    for role_id in roles {
        if !seen.contains(&role_id) {
            seen.push(role_id);
            state.hub.publish(Event::RoleChanged {
                role_id,
                change: None,
            });
        }
    }
}
