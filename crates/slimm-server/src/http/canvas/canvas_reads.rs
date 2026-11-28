// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas reads that name what they want rather than a region: objects by id, and the board's summary.
//!
//! All three share the viewport read's gate, [`canvas_read_access`]: seeing the channel is seeing its canvas.

use axum::extract::{Path, State};
use serde::Serialize;

use super::canvas_write::canvas_read_access;
use super::{CanvasObjectDto, ViewportDto, trim_to_byte_budget};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::extract::{AuthedLimited, CANVAS, Json};
use crate::http::messages::parse_uuid;
use crate::ids::{CanvasObjectId, ChannelId, UserId};
use crate::store::{BOARD_MAX_X, BOARD_MAX_Y, BOARD_MIN_X, BOARD_MIN_Y};

/// Most ids one `ids` read takes.
pub(super) const MAX_IDS: usize = 100;

#[derive(Serialize)]
pub(super) struct BoundsDto {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
}

#[derive(Serialize)]
pub(super) struct CanvasSummaryDto {
    /// Live objects on the board.
    count: i64,
    /// The box around every live object; null for an empty board.
    bounds: Option<BoundsDto>,
    /// The channel's canvas high-water mark, a valid `after_seq` for the op feed.
    latest_seq: i64,
    /// The board every object must lie inside.
    board: BoundsDto,
}

/// `GET /channels/{channel_id}/canvas/summary`.
pub(super) async fn summary(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CanvasSummaryDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    canvas_read_access(&state, ctx.user_id, channel_id).await?;
    let summary = state.store.canvas_summary(channel_id).await?;
    Ok(Json(CanvasSummaryDto {
        count: summary.count,
        bounds: summary.bounds.map(|rect| BoundsDto {
            min_x: rect.min_x,
            min_y: rect.min_y,
            max_x: rect.max_x,
            max_y: rect.max_y,
        }),
        latest_seq: summary.latest_seq,
        board: BoundsDto {
            min_x: BOARD_MIN_X,
            min_y: BOARD_MIN_Y,
            max_x: BOARD_MAX_X,
            max_y: BOARD_MAX_Y,
        },
    }))
}

/// `GET /channels/{channel_id}/canvas/objects/{object_id}`: one live object, as the viewport read shapes it.
pub(super) async fn object(
    AuthedLimited(ctx): AuthedLimited<CANVAS>,
    Path((channel_id, object_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<CanvasObjectDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let object_id = CanvasObjectId(parse_uuid(&object_id)?);
    canvas_read_access(&state, ctx.user_id, channel_id).await?;
    let (_, mut found) = state
        .store
        .canvas_objects_by_ids(channel_id, &[object_id])
        .await?;
    state
        .store
        .restore_blocked_canvas_authors(ctx.user_id, &mut found)
        .await?;
    found
        .pop()
        .map(|object| Json(CanvasObjectDto::from(object)))
        .ok_or(ApiError::NotFound("that object is not on this board"))
}

/// The `ids` form of the viewport read: those live objects, unknown ids absent.
pub(super) async fn by_ids(
    state: &AppState,
    viewer: UserId,
    channel_id: ChannelId,
    ids: &str,
) -> Result<Json<ViewportDto>, ApiError> {
    let ids = parse_ids(ids)?;
    let (latest_seq, mut objects) = state.store.canvas_objects_by_ids(channel_id, &ids).await?;
    let has_more = trim_to_byte_budget(&mut objects, false);
    state
        .store
        .restore_blocked_canvas_authors(viewer, &mut objects)
        .await?;
    Ok(Json(ViewportDto {
        objects: objects.into_iter().map(CanvasObjectDto::from).collect(),
        has_more,
        latest_seq,
        next_cursor: None,
        total_objects: None,
    }))
}

fn parse_ids(raw: &str) -> Result<Vec<CanvasObjectId>, ApiError> {
    let mut ids = Vec::new();
    for part in raw.split(',') {
        let id = CanvasObjectId(parse_uuid(part.trim())?);
        if !ids.contains(&id) {
            ids.push(id);
        }
        if ids.len() > MAX_IDS {
            return Err(ApiError::BadRequest("ids takes at most 100 object ids"));
        }
    }
    Ok(ids)
}
