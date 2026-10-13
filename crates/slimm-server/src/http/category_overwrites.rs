// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Category permissions (decision 0064): a category's own overwrites, and
//! syncing a channel back to them. The checks are the channel batch's own,
//! with the caller's deployment-wide permissions as the ceiling.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce, require_manage_roles};
use super::messages::parse_uuid;
use super::overwrites::{
    BatchSetRequest, MAX_BATCH_ENTRIES, OverwriteDto, OverwritesDto, Target, check_bits,
    parse_target, previously_visible_to, refuse_ungrantable,
};
use crate::hub::Event;
use crate::ids::{ChannelCategoryId, ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::OverwriteBatchEntry;

const BODY_LIMIT: usize = 16 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/categories/{category_id}/overwrites",
            get(list).put(batch_set),
        )
        .route("/channels/{channel_id}/overwrites/sync", post(sync))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

async fn live_category(state: &AppState, raw: &str) -> Result<ChannelCategoryId, ApiError> {
    let id = ChannelCategoryId(parse_uuid(raw)?);
    let exists = state
        .store
        .list_categories()
        .await?
        .iter()
        .any(|c| c.id == id);
    exists
        .then_some(id)
        .ok_or(ApiError::NotFound("category not found"))
}

async fn category_dto(state: &AppState, id: ChannelCategoryId) -> Result<OverwritesDto, ApiError> {
    let overwrites = state.store.category_overwrites(id).await?;
    Ok(OverwritesDto {
        overwrites: overwrites.into_iter().map(OverwriteDto::from).collect(),
        synced: None,
    })
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OverwritesDto>, ApiError> {
    require_manage_roles(&state, ctx.user_id).await?;
    let id = live_category(&state, &category_id).await?;
    Ok(Json(category_dto(&state, id).await?))
}

/// Who each synced channel's change affects and could already view it,
/// resolved before the write; see `overwrites::previously_visible_to`.
async fn visible_before(
    state: &AppState,
    channels: &[ChannelId],
    targets: &[Target],
) -> Result<Vec<(ChannelId, Vec<UserId>)>, ApiError> {
    let mut out = Vec::with_capacity(channels.len());
    for &channel in channels {
        let mut users = Vec::new();
        for target in targets {
            users.extend(previously_visible_to(state, channel, *target).await?);
        }
        users.sort();
        users.dedup();
        out.push((channel, users));
    }
    Ok(out)
}

/// Applies the entries to the category and copies the result into its synced
/// channels. An all-zero pair removes that target. Every entry is checked
/// before any writes, as the channel batch does.
async fn batch_set(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<BatchSetRequest>,
) -> Result<Json<OverwritesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let caller = require_manage_roles(&state, ctx.user_id).await?;
    let id = live_category(&state, &category_id).await?;
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
        let (old_allow, old_deny) = state
            .store
            .category_overwrite_for(id, target_type, target_id)
            .await?
            .unwrap_or((Permissions::NONE, Permissions::NONE));
        refuse_ungrantable(caller, allow.remove(old_allow).union(old_deny.remove(deny)))?;
        targets.push(target);
        entries.push(OverwriteBatchEntry {
            target_type,
            target_id,
            allow,
            deny,
        });
    }

    let synced = state.store.synced_channels_in(id).await?;
    let before = visible_before(&state, &synced, &targets).await?;
    state.store.set_category_overwrites(id, &entries).await?;
    for (channel_id, previously_visible_to) in before {
        state.hub.publish(Event::OverwriteChanged {
            channel_id,
            previously_visible_to,
        });
    }
    Ok(Json(category_dto(&state, id).await?))
}

/// Makes a channel follow its category again, adopting its overwrites.
async fn sync(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OverwritesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let caller = state
        .store
        .permissions_in_channel(ctx.user_id, channel_id)
        .await?;
    if !caller.contains(Permissions::MANAGE_ROLES) {
        return Err(ApiError::Forbidden);
    }
    let category = state
        .store
        .channel(channel_id)
        .await?
        .and_then(|c| c.category_id)
        .ok_or(ApiError::Conflict("the channel is not in a category"))?;
    // Syncing can grant what the category grants, so the caller must hold all of it.
    let mut targets = Vec::new();
    for o in state.store.category_overwrites(category).await? {
        refuse_ungrantable(caller, o.allow)?;
        targets.push(target_of(&o.target_type, o.target_id));
    }
    for o in state.store.channel_overwrites(channel_id).await? {
        targets.push(target_of(&o.target_type, o.target_id));
    }
    let before = visible_before(&state, &[channel_id], &targets).await?;
    state.store.sync_channel_permissions(channel_id).await?;
    for (channel_id, previously_visible_to) in before {
        state.hub.publish(Event::OverwriteChanged {
            channel_id,
            previously_visible_to,
        });
    }
    let overwrites = state.store.channel_overwrites(channel_id).await?;
    Ok(Json(OverwritesDto {
        overwrites: overwrites.into_iter().map(OverwriteDto::from).collect(),
        synced: Some(true),
    }))
}

fn target_of(kind: &str, id: uuid::Uuid) -> Target {
    match kind {
        "member" => Target::Member(UserId(id)),
        _ => Target::Role(crate::ids::RoleId(id)),
    }
}
