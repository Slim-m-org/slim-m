// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{channel_id}/canvas/export`: copy a board into a new canvas channel, clearing the original in the same commit (decision 0139).

use std::collections::HashSet;
use std::sync::{Arc, LazyLock, Mutex};

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::middleware::from_fn;
use axum::routing::post;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::category_sight::CategorySight;
use super::super::channels::channel_validation::validate_channel_name;
use super::super::channels::{ChannelDto, require_manager_who_sees};
use super::super::error::ApiError;
use super::super::extract::{CANVAS_EXPORT, Json};
use super::super::messages::parse_uuid;
use super::super::participant::Participant;
use super::super::post_commit::run_to_completion;
use super::canvas_ops_write::publish;
use super::canvas_write::ensure_may_draw;
use crate::hub::Event;
use crate::ids::{ChannelCategoryId, ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{CreateChannelError, ExportError, ExportRequest};

/// The body is a name and a few flags.
const BODY_LIMIT: usize = 16 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/canvas/export",
            post(export).layer(from_fn(run_to_completion)),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct ExportBody {
    /// The new channel; keys the whole request, so a retry never makes a second copy.
    id: String,
    name: String,
    /// Absent files the copy where the source is; null leaves it uncategorised.
    #[serde(default, deserialize_with = "super::super::space::present")]
    category_id: Option<Option<String>>,
    #[serde(default)]
    voice_enabled: Option<bool>,
    #[serde(default)]
    clear_source: Option<bool>,
}

#[derive(Serialize)]
struct ExportDto {
    channel: ChannelDto,
    copied: i64,
    skipped: i64,
    cleared: i64,
    spared: i64,
    left: i64,
}

/// Sources being exported right now. The server is one process, so a set is enough to hold a second export of one board off.
static IN_FLIGHT: LazyLock<Mutex<HashSet<ChannelId>>> = LazyLock::new(Mutex::default);

/// A source's place in [`IN_FLIGHT`], given back when the export ends however it ends.
struct ExportSlot(ChannelId);

impl ExportSlot {
    fn take(source: ChannelId) -> Option<Self> {
        let inserted = IN_FLIGHT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(source);
        // Built only once the lock is let go: a slot dropped under it would lock again and hang.
        if inserted { Some(Self(source)) } else { None }
    }
}

/// Holds `source` as being exported until the guard drops, so a test can meet a busy board without racing a real export.
#[doc(hidden)]
pub fn hold_export_slot(source: ChannelId) -> Option<impl Drop> {
    ExportSlot::take(source)
}

impl Drop for ExportSlot {
    fn drop(&mut self) {
        let mut busy = IN_FLIGHT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        busy.remove(&self.0);
    }
}

fn busy() -> ApiError {
    ApiError::Coded {
        status: StatusCode::CONFLICT,
        message: "This canvas is being exported already.",
        code: "canvas_export_busy",
    }
}

fn too_large() -> ApiError {
    ApiError::Coded {
        status: StatusCode::CONFLICT,
        message: "This canvas is too big to export.",
        code: "canvas_export_too_large",
    }
}

fn export_error(err: ExportError) -> ApiError {
    match err {
        ExportError::Channel(err) => err.into(),
        ExportError::TooLarge => too_large(),
        ExportError::Full => ApiError::Conflict("this canvas is full"),
        ExportError::SourceUnavailable => super::canvas_write::canvas_off(),
        ExportError::Internal(err) => {
            tracing::error!(error = %err, "canvas export failed");
            ApiError::Internal
        }
    }
}

/// The source's category, unless the caller named another or none.
async fn target_category(
    state: &AppState,
    user_id: UserId,
    asked: Option<Option<String>>,
    source_category: Option<ChannelCategoryId>,
) -> Result<Option<ChannelCategoryId>, ApiError> {
    let category = match asked {
        None => source_category,
        Some(raw) => raw
            .as_deref()
            .map(|raw| parse_uuid(raw).map(ChannelCategoryId))
            .transpose()?,
    };
    if let Some(category) = category
        && CategorySight::of(state, user_id).await?.shuts(category)
    {
        return Err(CreateChannelError::UnknownCategory.into());
    }
    Ok(category)
}

/// Who may export: a channel manager who may draw on the source, and clear it only with `MANAGE_CANVAS` there.
async fn require_exporter(
    state: &AppState,
    user_id: UserId,
    source_id: ChannelId,
    clear_source: bool,
) -> Result<Option<ChannelCategoryId>, ApiError> {
    require_manager_who_sees(state, user_id, source_id).await?;
    let source = state
        .store
        .channel_including_deleted(source_id)
        .await?
        .ok_or(ApiError::NotFound("channel not found"))?;
    let permissions = ensure_may_draw(state, user_id, source_id).await?;
    if clear_source && !permissions.contains(Permissions::MANAGE_CANVAS) {
        return Err(ApiError::Forbidden);
    }
    Ok(source.category_id)
}

/// Copies the source's board into a new canvas channel with the source's audience, and clears the source when asked.
///
/// Idempotent by `id`: a retry answers the stored outcome, ignoring a changed name, category or `voice_enabled`, and publishes nothing.
/// A replay is charged like any attempt, since the rate limit runs before the body is read.
async fn export(
    Participant(ctx): Participant<CANVAS_EXPORT>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<ExportBody>,
) -> Result<Json<ExportDto>, ApiError> {
    let source_id = ChannelId(parse_uuid(&channel_id)?);
    let id = ChannelId(parse_uuid(&body.id)?);
    let clear_source = body.clear_source == Some(true);
    let source_category = require_exporter(&state, ctx.user_id, source_id, clear_source).await?;
    let name = validate_channel_name(&body.name)?;
    let category_id =
        target_category(&state, ctx.user_id, body.category_id, source_category).await?;
    let _slot = ExportSlot::take(source_id).ok_or_else(busy)?;
    state
        .store
        .check_canvas_export(id, source_id)
        .await
        .map_err(export_error)?;

    let done = state
        .store
        .export_canvas_to_new_channel(ExportRequest {
            id,
            source_id,
            actor_id: ctx.user_id,
            name,
            category_id,
            voice_enabled: body.voice_enabled == Some(true),
            clear_source,
        })
        .await
        .map_err(export_error)?;
    let restricted = state.store.channel_restricted(done.channel.id).await?;
    if done.fresh {
        state.hub.publish(Event::ChannelCreated(
            Arc::new(done.channel.clone()),
            restricted,
        ));
        if let Some(op) = &done.clear_op {
            publish(&state, source_id, op.id, op);
        }
    }
    Ok(Json(ExportDto {
        channel: ChannelDto::with_restricted(done.channel, restricted),
        copied: done.copied,
        skipped: done.skipped,
        cleared: done.cleared,
        spared: done.spared,
        left: done.left,
    }))
}
