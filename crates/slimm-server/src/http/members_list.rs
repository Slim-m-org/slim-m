// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /members`: the deployment's member list for the member pane.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::routing::get;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, Query};
use super::messages::parse_uuid;
use super::users::{UserDto, to_dtos};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

const BODY_LIMIT: usize = 4 * 1024;

/// Default and maximum page sizes for the member list.
const MEMBERS_DEFAULT_LIMIT: i64 = 50;
const MEMBERS_MAX_LIMIT: i64 = 200;

/// The member list route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/members", get(list_members))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct ListMembersParams {
    after: Option<String>,
    limit: Option<i64>,
    /// Narrows the roster to who can view this channel; see [`list_members`].
    channel: Option<String>,
}

/// Lists the deployment's live members for a member list. Any authenticated
/// caller may read it: a member list is deployment-wide, not scoped to any
/// one channel, so there is no channel permission to check it against.
///
/// `channel` narrows the roster to the members who can view that channel,
/// which is what a member pane beside a channel means by "who is here". The
/// caller must be able to view that channel themselves: the viewer set of a
/// restricted channel or a dm is not part of the deployment-wide roster, and a
/// channel the caller cannot view answers 404 like one that does not exist.
///
/// A MANAGE_ROLES caller additionally gets each member's registration invite
/// code attached (see MOD9) - a moderation signal, not a public one, so it
/// is fetched and attached only here rather than in [`to_dtos`] itself,
/// which every other `UserDto` response also goes through.
///
/// MANAGE_ROLES rather than the BAN_MEMBERS this once used: a code is a
/// credential, not a label. `Store::redeem_invite` applies the invite's
/// `role_grant` to whoever spends it, and redeeming needs nothing but a
/// session, so a moderator who could not grant a role could read a still-live
/// code off this list and take that role - up to ADMINISTRATOR. Gating on the
/// permission that could grant it anyway closes that without losing the
/// ban-evasion signal for the people who set the roles in the first place.
async fn list_members(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<ListMembersParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserDto>>, ApiError> {
    let after = params
        .after
        .as_deref()
        .map(parse_uuid)
        .transpose()?
        .map(UserId);
    let limit = params
        .limit
        .unwrap_or(MEMBERS_DEFAULT_LIMIT)
        .clamp(1, MEMBERS_MAX_LIMIT);

    let members = match params.channel.as_deref().map(parse_uuid).transpose()? {
        Some(id) => {
            let channel_id = ChannelId(id);
            // A hidden channel answers like a missing one; see decision 0011.
            if !state
                .store
                .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
                .await?
            {
                return Err(ApiError::NotFound("channel not found"));
            }
            state
                .store
                .list_members_who_view(channel_id, after, limit)
                .await?
        }
        None => state.store.list_members(after, limit).await?,
    };
    let ids: Vec<UserId> = members.iter().map(|m| m.id).collect();
    let mut dtos = to_dtos(&state.store, members).await?;

    // A code is a credential: redeeming it applies the role it grants.
    let sees_codes = state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_ROLES);
    if sees_codes {
        let invite_codes = state.store.registration_invite_codes(&ids).await?;
        for (dto, id) in dtos.iter_mut().zip(ids.iter()) {
            dto.invite_code = invite_codes.get(id).cloned();
        }
    }
    Ok(Json(dtos))
}
