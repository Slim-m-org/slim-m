// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module tile's shared frame: `GET` reads it, `POST` presses it.
//!
//! This is the app surface protocol of `code_runs`, keyed by a canvas object
//! rather than a message: the host holds the frame's `state`, presses are
//! applied one at a time, a failed or private answer reaches only the presser,
//! and a stored frame is broadcast to every viewer of the canvas as
//! `canvas.tile.scene_changed`. The module runs as whoever pressed.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::get;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::code_runs::{is_private_scene, stored_payload};
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json, MODULE};
use super::super::messages::parse_uuid;
use super::super::module_commands::execute_on_canvas;
use super::super::scene_refresh::requested_ms;
use super::super::surface_lock::lock_canvas_tile;
use super::super::surface_state::with_held_state;
use super::canvas_module_tiles::runnable_tile;
use super::canvas_write::canvas_read_access;
use crate::hub::{CanvasEvent, Event};
use crate::ids::{CanvasObjectId, ChannelId, UserId};
use crate::store::{ModuleTileRef, now_ms};

/// A press is an action frame, plus whatever a scene's text field holds.
const BODY_LIMIT: usize = 16 * 1024;

/// How long a redraw chain runs after the last press, as for a message's app surface.
const REFRESH_WINDOW_MS: i64 = 30 * 60_000;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/canvas/objects/{object_id}/scene",
            get(read).post(press),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct TileSceneDto {
    object_id: String,
    output: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    ran_by: Option<String>,
    ran_at: i64,
}

#[derive(Deserialize)]
struct PressRequest {
    #[serde(default)]
    input: String,
}

/// The `{ok, output}` / `{ok, error}` answer of every module run route.
#[derive(Serialize)]
struct PressResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl PressResponse {
    fn answered(ok: bool, payload: String) -> Self {
        let (output, error) = if ok {
            (Some(payload), None)
        } else {
            (None, Some(payload))
        };
        Self { ok, output, error }
    }
}

fn ids(channel_id: &str, object_id: &str) -> Result<(ChannelId, CanvasObjectId), ApiError> {
    Ok((
        ChannelId(parse_uuid(channel_id)?),
        CanvasObjectId(parse_uuid(object_id)?),
    ))
}

async fn live_tile(
    state: &AppState,
    channel_id: ChannelId,
    object_id: CanvasObjectId,
) -> Result<ModuleTileRef, ApiError> {
    state
        .store
        .live_module_tile(channel_id, object_id)
        .await?
        .ok_or(ApiError::NotFound("no module tile with that id"))
}

/// The tile's frame; 404 before its first launch, 409 with the reason when its module cannot run.
async fn read(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
    Path((channel_id, object_id)): Path<(String, String)>,
) -> Result<Json<TileSceneDto>, ApiError> {
    let (channel_id, object_id) = ids(&channel_id, &object_id)?;
    canvas_read_access(&state, ctx.user_id, channel_id).await?;
    let tile = live_tile(&state, channel_id, object_id).await?;
    runnable_tile(&state, &tile).await?;
    let scene = state
        .store
        .canvas_tile_scene(object_id)
        .await?
        .ok_or(ApiError::NotFound("this tile has no frame yet"))?;
    Ok(Json(TileSceneDto {
        object_id: object_id.to_string(),
        output: scene.output,
        ran_by: scene.ran_by.map(|id| id.to_string()),
        ran_at: scene.ran_at,
    }))
}

/// Runs the tile's command as the caller on the held frame; a press with nothing stored yet launches it.
async fn press(
    AuthedLimited(ctx): AuthedLimited<MODULE>,
    State(state): State<AppState>,
    Path((channel_id, object_id)): Path<(String, String)>,
    Json(req): Json<PressRequest>,
) -> Result<Json<PressResponse>, ApiError> {
    let (channel_id, object_id) = ids(&channel_id, &object_id)?;
    canvas_read_access(&state, ctx.user_id, channel_id).await?;
    // The frame is shown to the whole call, so a timeout bars it like a message.
    if state.store.timed_out_until(ctx.user_id).await?.is_some() {
        return Err(ApiError::Forbidden);
    }
    let tile = live_tile(&state, channel_id, object_id).await?;
    let (module, command) = runnable_tile(&state, &tile).await?;

    let _turn = lock_canvas_tile(object_id).await;
    let (ok, payload) = run_once(
        &state,
        (channel_id, object_id),
        (&module.id, &command),
        (ctx.user_id, &req.input),
    )
    .await?;
    if !ok || is_private_scene(&payload) {
        return Ok(Json(PressResponse::answered(ok, payload)));
    }
    publish(&state, (channel_id, object_id), &payload, ctx.user_id).await?;
    match requested_ms(&payload) {
        Some(ms) => note_refresh(&state, object_id, ms, None).await,
        None => stop_refresh(&state, object_id).await,
    }
    Ok(Json(PressResponse::answered(true, payload)))
}

/// One run of the tile's command on its held frame; the caller holds the tile's turn.
async fn run_once(
    state: &AppState,
    (channel_id, object_id): (ChannelId, CanvasObjectId),
    (module_id, command): (&str, &str),
    (user_id, input): (UserId, &str),
) -> Result<(bool, String), ApiError> {
    let stored = state.store.canvas_tile_scene(object_id).await?;
    let input = with_held_state(input, stored.as_ref().map(|s| s.output.as_str()));
    let outcome =
        execute_on_canvas(state, user_id, (module_id, command, &input), channel_id).await?;
    Ok(stored_payload(false, outcome))
}

async fn publish(
    state: &AppState,
    (channel_id, object_id): (ChannelId, CanvasObjectId),
    output: &str,
    ran_by: UserId,
) -> Result<(), ApiError> {
    let ran_at = state
        .store
        .record_canvas_tile_scene((channel_id, object_id), output, ran_by)
        .await?;
    state
        .hub
        .publish(Event::Canvas(CanvasEvent::TileSceneChanged {
            channel_id,
            object_id,
            output: Arc::from(output),
            ran_by: Some(ran_by),
            ran_at,
        }));
    Ok(())
}

/// Queues the next redraw; `until_at` is a running chain's end, `None` a person's press.
async fn note_refresh(state: &AppState, object_id: CanvasObjectId, ms: i64, until_at: Option<i64>) {
    let now = now_ms();
    let (until, extend) = match until_at {
        Some(until) => (until, false),
        None => (now + REFRESH_WINDOW_MS, true),
    };
    if let Err(err) = state
        .store
        .schedule_canvas_tile_refresh(object_id, (now + ms, until), extend)
        .await
    {
        tracing::warn!(%err, "could not queue a tile redraw");
    }
}

async fn stop_refresh(state: &AppState, object_id: CanvasObjectId) {
    if let Err(err) = state.store.clear_canvas_tile_refresh(object_id).await {
        tracing::warn!(%err, "could not clear a tile redraw");
    }
}

/// Redraws every tile whose time has come, as the person who last pressed it; returns how many were redrawn.
pub(in crate::http) async fn run_due(state: &AppState, now: i64) -> anyhow::Result<usize> {
    let mut redrawn = 0;
    for (object_id, channel_id, until_at) in state.store.due_canvas_tile_refreshes(now, 16).await? {
        if now >= until_at {
            stop_refresh(state, object_id).await;
            continue;
        }
        match redraw(state, channel_id, object_id).await {
            Some(ms) => {
                note_refresh(state, object_id, ms, Some(until_at)).await;
                redrawn += 1;
            }
            None => stop_refresh(state, object_id).await,
        }
    }
    Ok(redrawn)
}

/// Runs the tile once with `refresh`; the interval to ask again after, or `None` to stop.
async fn redraw(state: &AppState, channel_id: ChannelId, object_id: CanvasObjectId) -> Option<i64> {
    let tile = state
        .store
        .live_module_tile(channel_id, object_id)
        .await
        .ok()??;
    let (module, command) = runnable_tile(state, &tile).await.ok()?;
    let _turn = lock_canvas_tile(object_id).await;
    let person = state
        .store
        .canvas_tile_scene(object_id)
        .await
        .ok()??
        .ran_by?;
    canvas_read_access(state, person, channel_id).await.ok()?;
    if state.store.timed_out_until(person).await.ok()?.is_some() {
        return None;
    }
    let (ok, payload) = run_once(
        state,
        (channel_id, object_id),
        (&module.id, &command),
        (person, r#"{"action":"refresh"}"#),
    )
    .await
    .ok()?;
    if !ok || is_private_scene(&payload) {
        return None;
    }
    publish(state, (channel_id, object_id), &payload, person)
        .await
        .ok()?;
    requested_ms(&payload)
}
