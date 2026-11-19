// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Minting, listing, renaming, rotating and revoking webhooks. See
//! `docs/decisions/0030-incoming-webhooks.md`, and its "admin surface"
//! addendum for what this file's routes had to decide beyond delivery.
//!
//! `MANAGE_SERVER` is the gate, and every route also follows the webhook's
//! channel ([`Reach`]): one the caller cannot see is as good as missing, and a
//! credential that posts is only handed to someone who may post there. An
//! administrator lists and revokes every webhook, so none outlives its off switch.
//!
//! Gated on `MANAGE_SERVER` exactly like `bots.rs`, and deliberately not
//! reusing any of its handlers: a webhook has no permissions to grant and no
//! session to revoke, so the shapes that make up most of that file (the
//! managed role, `require_human`, escalation guards) do not apply here.
//!
//! The token is returned exactly once, by [`create`], and unrecoverable
//! afterwards - the same shape `bots.rs::create` uses.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::auth::validate_label;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_base_permission, require_manage_server};
use super::messages::parse_uuid;
use crate::ids::{ChannelId, UserId, WebhookId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{DM_CHANNEL_KIND, Webhook};

/// A create or rename body is a channel id and a short label; nowhere near
/// the delivery route's own, much larger, body limit.
const BODY_LIMIT: usize = 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/webhooks", get(list).post(create))
        .route("/webhooks/{webhook_id}", patch(rename))
        .route("/webhooks/{webhook_id}/rotate", post(rotate))
        .route("/webhooks/{webhook_id}/revoke", post(revoke))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct CreateWebhookDto {
    channel_id: String,
    label: String,
}

#[derive(Deserialize)]
struct RenameWebhookDto {
    label: String,
}

/// A webhook, as the admin surface lists it. Never carries a token.
#[derive(Serialize)]
struct WebhookDto {
    id: String,
    channel_id: String,
    label: String,
    created_at: i64,
    last_delivery_at: Option<i64>,
    /// Absent if the admin who minted this has since deleted their own
    /// account; the webhook itself keeps working either way.
    created_by_display_name: Option<String>,
}

impl From<Webhook> for WebhookDto {
    fn from(webhook: Webhook) -> Self {
        Self {
            id: webhook.id.to_string(),
            channel_id: webhook.channel_id.to_string(),
            label: webhook.label,
            created_at: webhook.created_at,
            last_delivery_at: webhook.last_delivery_at,
            created_by_display_name: webhook.created_by_display_name,
        }
    }
}

/// A created webhook, with its delivery path. The only response that ever
/// carries it.
///
/// A path (`/webhooks/{id}/{token}`), not a full URL: the server has no
/// notion of its own externally reachable origin (it may sit behind a
/// reverse proxy at any hostname), while the client already knows the
/// address it is talking to this deployment on. The client joins the two to
/// show a pasteable URL.
#[derive(Serialize)]
struct NewWebhookDto {
    webhook: WebhookDto,
    delivery_path: String,
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<Vec<WebhookDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    let webhooks = state.store.list_webhooks().await?;
    if is_administrator(&state, ctx.user_id).await? {
        return Ok(Json(webhooks.into_iter().map(WebhookDto::from).collect()));
    }
    let channels: Vec<ChannelId> = webhooks.iter().map(|w| w.channel_id).collect();
    let held = state
        .store
        .permissions_in_channels(ctx.user_id, &channels)
        .await?;
    let visible = webhooks.into_iter().filter(|webhook| {
        held.get(&webhook.channel_id)
            .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
    });
    Ok(Json(visible.map(WebhookDto::from).collect()))
}

/// Refuses a caller without `MANAGE_SERVER`, and says whether they are an administrator:
/// the one caller a webhook in a direct message or a deleted channel is still listed for.
async fn is_administrator(state: &AppState, user: UserId) -> Result<bool, ApiError> {
    let held = require_base_permission(state, user, Permissions::MANAGE_SERVER).await?;
    Ok(held.contains(Permissions::ADMINISTRATOR))
}

/// What a caller may do with the webhooks of one channel.
enum Reach {
    /// They cannot see the channel, so its webhooks do not exist for them.
    Hidden,
    /// They can see it but not post in it: enough to rename or revoke.
    Visible,
    /// They could post there themselves, so they may hold a credential that does.
    Posting,
}

impl Reach {
    async fn of(state: &AppState, user: UserId, channel: ChannelId) -> Result<Self, ApiError> {
        let held = state.store.permissions_in_channel(user, channel).await?;
        Ok(if !held.contains(Permissions::VIEW_CHANNEL) {
            Self::Hidden
        } else if held.contains(Permissions::SEND_MESSAGES) {
            Self::Posting
        } else {
            Self::Visible
        })
    }
}

/// The webhook and the caller's reach over it, or the 404 a hidden one shares with a missing one.
async fn reachable(
    state: &AppState,
    user: UserId,
    webhook_id: WebhookId,
) -> Result<(Webhook, Reach), ApiError> {
    let missing = ApiError::NotFound("no such webhook");
    let listed = state.store.list_webhooks().await?;
    let Some(webhook) = listed.into_iter().find(|w| w.id == webhook_id) else {
        return Err(missing);
    };
    match Reach::of(state, user, webhook.channel_id).await? {
        Reach::Hidden => Err(missing),
        reach => Ok((webhook, reach)),
    }
}

/// Labels follow the same rule a display name does: `validate_label`, not a
/// bespoke check, so a webhook's name is held to the same bar a person's is.
async fn create(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(body): Json<CreateWebhookDto>,
) -> Result<(StatusCode, Json<NewWebhookDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;

    let label = body.label.trim();
    validate_label(label, "label must be 1 to 64 characters")?;
    let channel_id = ChannelId(parse_uuid(&body.channel_id)?);
    // A direct message is its parties' alone: no webhook posts into one, whoever asks.
    let channel = state.store.channel(channel_id).await?;
    if !channel.is_some_and(|channel| channel.kind != DM_CHANNEL_KIND) {
        return Err(ApiError::NotFound("no such channel"));
    }
    match Reach::of(&state, ctx.user_id, channel_id).await? {
        Reach::Hidden => return Err(ApiError::NotFound("no such channel")),
        Reach::Visible => return Err(ApiError::Forbidden),
        Reach::Posting => {}
    }

    let minted = state
        .store
        .create_webhook(channel_id, label, ctx.user_id)
        .await?;
    let delivery_path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    Ok((
        StatusCode::CREATED,
        Json(NewWebhookDto {
            webhook: minted.webhook.into(),
            delivery_path,
        }),
    ))
}

/// Renames a webhook's admin-facing label. Returns 404 rather than a
/// permission-shaped refusal for an id that never existed, the same uniform
/// answer delivery gives an unknown id.
async fn rename(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(webhook_id): Path<String>,
    Json(body): Json<RenameWebhookDto>,
) -> Result<Json<WebhookDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let webhook_id = WebhookId(parse_uuid(&webhook_id)?);

    let label = body.label.trim();
    validate_label(label, "label must be 1 to 64 characters")?;
    reachable(&state, ctx.user_id, webhook_id).await?;

    match state.store.rename_webhook(webhook_id, label).await? {
        Some(webhook) => Ok(Json(webhook.into())),
        None => Err(ApiError::NotFound("no such webhook")),
    }
}

/// Issues a new token for a webhook, keeping its principal. The old URL 404s
/// from the same commit; the new path is returned here and never again.
async fn rotate(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(webhook_id): Path<String>,
) -> Result<Json<NewWebhookDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let webhook_id = WebhookId(parse_uuid(&webhook_id)?);
    if !matches!(
        reachable(&state, ctx.user_id, webhook_id).await?,
        (_, Reach::Posting)
    ) {
        return Err(ApiError::Forbidden);
    }
    let Some((webhook, token)) = state.store.rotate_webhook(webhook_id, ctx.user_id).await? else {
        return Err(ApiError::NotFound("no such webhook"));
    };
    let delivery_path = format!("/webhooks/{}/{}", webhook.id, token);
    Ok(Json(NewWebhookDto {
        webhook: webhook.into(),
        delivery_path,
    }))
}

/// Revokes a webhook. Its URL 404s on its very next delivery attempt - see
/// `Store::revoke_webhook`'s own doc for why there is nothing else to close.
async fn revoke(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(webhook_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let webhook_id = WebhookId(parse_uuid(&webhook_id)?);
    // Revoking hands out nothing, so an administrator may do it wherever the webhook points.
    if !is_administrator(&state, ctx.user_id).await? {
        reachable(&state, ctx.user_id, webhook_id).await?;
    }
    if !state.store.revoke_webhook(webhook_id, ctx.user_id).await? {
        return Err(ApiError::NotFound("no such webhook"));
    }
    Ok(StatusCode::NO_CONTENT)
}
