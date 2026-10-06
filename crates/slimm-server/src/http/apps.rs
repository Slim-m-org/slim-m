// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! App routes: create a message that launches an installed module's `app`
//! extension point, and discover which apps a caller may launch.
//!
//! Launching an app is not its own resource: it is a message, so creating one
//! goes through the same idempotent-by-id, per-channel `seq` allocation every
//! other message send does (see [`crate::store::Store::send_app_message`]). The
//! surface's live, shared state is not created here - it is the module's own
//! output, which the client runs and everyone sees through the shared code-run
//! route (`super::code_runs`) at block 0, exactly like a fenced code block. slim
//! keeps no notion of what any app does.
//!
//! `GET /modules/apps` mirrors `GET /modules/slash-commands`: per caller, which
//! installed and enabled module declared an `app` extension point the caller
//! holds the permission for. A deployment with no such module answers an empty
//! list - no launchable apps anywhere in the client.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::channel_slow_mode::enforce_slow_mode;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::{MessageDto, parse_uuid};
use super::module_commands::reachable_extension_points;
use super::post_commit::after_commit;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{AppSurface as StoreAppSurface, CreateAppSurfaceError, Store};

/// An app-launch body is tiny: which module and command, plus an optional
/// caption and the client-generated id.
const APP_BODY_LIMIT: usize = 8 * 1024;
/// Longest an optional caption riding alongside a launched app may be, matching
/// the cap ordinary message content already carries.
const CAPTION_MAX_CHARS: usize = 4000;

/// The app routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/messages/apps", post(create))
        .route("/modules/apps", get(list_apps))
        .layer(DefaultBodyLimit::max(APP_BODY_LIMIT))
}

// --- Wire types ---

/// An app surface as it appears on a message: which module and command it
/// launches, so the client renders the shared, interactive surface (fed by the
/// code-run at block 0) rather than the message's text.
#[derive(Serialize)]
pub(crate) struct AppSurfaceDto {
    module_id: String,
    command: String,
}

impl From<StoreAppSurface> for AppSurfaceDto {
    fn from(surface: StoreAppSurface) -> Self {
        Self {
            module_id: surface.module_id,
            command: surface.command,
        }
    }
}

/// One `app` extension point a caller may launch: the module and command to
/// post, plus the `name`/`description` the composer's apps menu shows.
#[derive(Serialize)]
struct AppDto {
    module_id: String,
    command: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

#[derive(Deserialize)]
struct LaunchAppRequest {
    /// Client-generated UUID (v7 preferred), exactly like an ordinary send;
    /// makes creation idempotent the same way.
    id: String,
    /// An optional caption riding alongside the app. May be empty: the app
    /// itself, not this field, is what an app message is for.
    #[serde(default)]
    content: String,
    module_id: String,
    command: String,
}

/// Batch-attaches app-surface data to already-built message DTOs, called from
/// [`super::message_enrich::with_reactions`] so every consumer of that shared
/// enrichment (list, search, sync, pinned) renders a launched app without its
/// own call site or database round trip.
///
/// `ids` and `dtos` must be the same length and in the same order, which holds
/// because both come from the same source list in `with_reactions`.
///
/// Takes `&Store` rather than `&AppState`: nothing here reads any other field.
pub(crate) async fn attach_app_surfaces(
    store: &Store,
    ids: &[MessageId],
    dtos: &mut [MessageDto],
) -> anyhow::Result<()> {
    let surfaces = store.app_surfaces_for_messages(ids).await?;
    for (message_id, surface) in surfaces {
        if let Some(pos) = ids.iter().position(|id| *id == message_id) {
            dtos[pos].app_surface = Some(surface.into());
        }
    }
    Ok(())
}

// --- Handlers ---

async fn create(
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<LaunchAppRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    // Launching an app is a message send, gated exactly like one: view plus send, evaluated in this channel.
    let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, needed)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    // Refuse launching an app the caller could never see offered, by the same three checks discovery filters on; the run gate is re-checked per run inside execute_command.
    if !caller_may_launch(&state, ctx.user_id, &req.module_id, &req.command).await? {
        return Err(ApiError::Forbidden);
    }

    let content = validate_caption(&req.content)?;
    let id = MessageId(parse_uuid(&req.id)?);
    // Never on a retry: a launch that already landed must not be refused for arriving too soon.
    if state.store.message_including_deleted(id).await?.is_none() {
        enforce_slow_mode(&state, channel_id, ctx.user_id).await?;
    }
    let sent = match state
        .store
        .send_app_message(
            channel_id,
            ctx.user_id,
            id,
            content,
            &req.module_id,
            &req.command,
        )
        .await
    {
        Ok(sent) => sent,
        Err(CreateAppSurfaceError::IdConflict) => {
            return Err(ApiError::Conflict("message id already used"));
        }
        Err(CreateAppSurfaceError::Internal(e)) => return Err(e.into()),
    };

    let surface = after_commit(
        "its app surface",
        state.store.app_surface_for_message(id).await,
    );
    let mut dto = MessageDto::from(sent.message.clone());
    if let Some(surface) = surface.clone() {
        dto.app_surface = Some(surface.into());
    }

    if sent.fresh {
        // An app message's caption can carry a mention like any other message's content.
        after_commit(
            "its mentions",
            super::message_mentions::resolve_and_store(
                &state,
                channel_id,
                ctx.user_id,
                sent.message.id,
                &sent.message.content,
            )
            .await,
        );
        super::read_sync::advance_for_author(&state, ctx.user_id, &sent.message).await;

        // A run can race this send, so block 0 may already exist by now.
        let block_zero = after_commit(
            "its code run",
            state.store.code_runs_for_messages(&[sent.message.id]).await,
        )
        .into_iter()
        .next()
        .and_then(|(_, runs)| runs.into_iter().find(|r| r.block_index == 0));

        state.hub.publish(Event::MessageCreated {
            message: Arc::new(sent.message.clone()),
            attachments: Arc::new(Vec::new()),
            forwarded: None,
            app_surface: surface.map(Arc::new),
            code_run: block_zero.map(Arc::new),
            poll: None,
            embeds: Arc::new(Vec::new()),
            call: None,
            components: std::sync::Arc::new(Vec::new()),
        });
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id,
                author_id: ctx.user_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: state.hub.presence(),
            },
        );
        super::threads::notify_reply(&state, channel_id).await;
    }

    Ok(Json(dto))
}

/// Whether `user_id` may launch `command` on `module_id`: the same three checks
/// [`list_apps`] filters on, so a launch can only name an app that discovery
/// would have offered. Installed, enabled, an `app` extension point of that
/// command exists, and the caller holds its declared permission.
async fn caller_may_launch(
    state: &AppState,
    user_id: UserId,
    module_id: &str,
    command: &str,
) -> anyhow::Result<bool> {
    let Some(module) = state.store.installed_module(module_id).await? else {
        return Ok(false);
    };
    if !module.enabled {
        return Ok(false);
    }
    let Some(ep) = module
        .extension_points
        .iter()
        .find(|e| e.kind == "app" && e.command.as_deref() == Some(command))
    else {
        return Ok(false);
    };
    let Some(permission) = &ep.permission else {
        return Ok(false);
    };
    state
        .store
        .user_has_module_permission(user_id, module_id, permission)
        .await
}

/// Every `app` extension point the caller may currently launch: installed,
/// enabled, and the caller holds the permission it declared. Mirrors
/// [`super::module_commands`]'s slash-command listing exactly; never a
/// hardcoded module id, per docs/decisions/0021's module-agnostic principle.
/// Possibly empty.
async fn list_apps(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<AppDto>>, ApiError> {
    let apps = reachable_extension_points(&state, ctx.user_id, "app")
        .await?
        .into_iter()
        .map(|r| AppDto {
            module_id: r.module_id,
            command: r.command,
            name: r.point.name,
            description: r.point.description,
        })
        .collect();
    Ok(Json(apps))
}

fn validate_caption(content: &str) -> Result<&str, ApiError> {
    if content.chars().count() > CAPTION_MAX_CHARS {
        return Err(ApiError::BadRequest("caption is too long"));
    }
    Ok(content)
}
