// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Category permissions (decisions 0064 and 0120): a category's overwrites, and syncing a channel
//! or sub-category back to its parent's, with the caller's deployment-wide permissions as the ceiling.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce, require_manage_roles};
use super::messages::parse_uuid;
use super::overwrite_changes::{publish_changed, target_of, visible_before};
use super::overwrites::{
    BatchSetRequest, MAX_BATCH_ENTRIES, OverwriteDto, OverwritesDto, Target, check_bits,
    parse_target, refuse_ungrantable,
};
use crate::ids::{ChannelCategoryId, ChannelId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{ChannelCategory, ChannelOverwrite, OverwriteBatchEntry};

const BODY_LIMIT: usize = 16 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/categories/{category_id}/overwrites",
            get(list).put(batch_set),
        )
        .route("/channels/{channel_id}/overwrites/sync", post(sync))
        .route(
            "/categories/{category_id}/overwrites/sync",
            post(sync_category),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

async fn live_category(state: &AppState, raw: &str) -> Result<ChannelCategory, ApiError> {
    let id = ChannelCategoryId(parse_uuid(raw)?);
    state
        .store
        .category(id)
        .await?
        .ok_or(ApiError::NotFound("category not found"))
}

/// The category's overwrites; `synced` says whether a sub-category follows its parent.
async fn category_dto(state: &AppState, id: ChannelCategoryId) -> Result<OverwritesDto, ApiError> {
    let overwrites = state.store.category_overwrites(id).await?;
    Ok(OverwritesDto {
        overwrites: overwrites.into_iter().map(OverwriteDto::from).collect(),
        synced: state.store.category_sync_state(id).await?.flatten(),
    })
}

async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OverwritesDto>, ApiError> {
    require_manage_roles(&state, ctx.user_id).await?;
    let id = live_category(&state, &category_id).await?.id;
    Ok(Json(category_dto(&state, id).await?))
}

/// Applies the entries and copies the result into everything synced beneath. Every entry is
/// checked first; a synced sub-category held the parent's old rows, so the copy adds only what passed.
async fn batch_set(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<BatchSetRequest>,
) -> Result<Json<OverwritesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let caller = require_manage_roles(&state, ctx.user_id).await?;
    let id = live_category(&state, &category_id).await?.id;
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

    let synced = state.store.synced_channels_beneath(id).await?;
    let before = visible_before(&state, &synced, &targets).await?;
    state.store.set_category_overwrites(id, &entries).await?;
    publish_changed(&state, before);
    Ok(Json(category_dto(&state, id).await?))
}

/// Refuses a sync that grants more than the caller holds, and returns every target it touches.
/// Adopting `parent`'s rows grants what they allow, and dropping a deny of `own` they lack grants it back.
fn refuse_sync_escalation(
    caller: Permissions,
    parent: &[ChannelOverwrite],
    own: &[ChannelOverwrite],
) -> Result<Vec<Target>, ApiError> {
    let mut targets = Vec::with_capacity(parent.len() + own.len());
    for o in parent {
        refuse_ungrantable(caller, o.allow)?;
        targets.push(target_of(&o.target_type, o.target_id));
    }
    for o in own {
        let kept = parent
            .iter()
            .find(|p| p.target_type == o.target_type && p.target_id == o.target_id)
            .map_or(Permissions::NONE, |p| p.deny);
        refuse_ungrantable(caller, o.deny.remove(kept))?;
        targets.push(target_of(&o.target_type, o.target_id));
    }
    Ok(targets)
}

/// Makes a sub-category follow its parent again (decision 0120), adopting
/// the parent's overwrites and copying them into its own synced channels.
async fn sync_category(
    Authed(ctx): Authed,
    parts: Parts,
    Path(category_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OverwritesDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let caller = require_manage_roles(&state, ctx.user_id).await?;
    let category = live_category(&state, &category_id).await?;
    let parent = category.parent_id.ok_or(ApiError::Conflict(
        "a top-level category has no parent to follow",
    ))?;
    let targets = refuse_sync_escalation(
        caller,
        &state.store.category_overwrites(parent).await?,
        &state.store.category_overwrites(category.id).await?,
    )?;
    let channels = state.store.synced_channels_beneath(category.id).await?;
    let before = visible_before(&state, &channels, &targets).await?;
    state.store.sync_category_permissions(category.id).await?;
    publish_changed(&state, before);
    Ok(Json(category_dto(&state, category.id).await?))
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
    let targets = refuse_sync_escalation(
        caller,
        &state.store.category_overwrites(category).await?,
        &state.store.channel_overwrites(channel_id).await?,
    )?;
    let before = visible_before(&state, &[channel_id], &targets).await?;
    state.store.sync_channel_permissions(channel_id).await?;
    publish_changed(&state, before);
    let overwrites = state.store.channel_overwrites(channel_id).await?;
    Ok(Json(OverwritesDto {
        overwrites: overwrites.into_iter().map(OverwriteDto::from).collect(),
        synced: Some(true),
    }))
}
