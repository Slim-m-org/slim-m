// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Module tiles on a canvas: which `canvas-tile` points a member may place
//! (`GET /modules/canvas-tiles`), and the check the place route runs on a
//! `module` object before it writes.
//!
//! A tile is an ordinary canvas object of kind `module`, so it moves, resizes,
//! restacks, locks and is removed through the same ops as a note. Its frame is
//! the module's own scene, run and shared by `canvas_tile_scene`.

use axum::Router;
use axum::extract::State;
use axum::routing::get;
use serde::Serialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::super::module_commands::{ModuleInfoDto, reachable_extension_points};
use crate::ids::UserId;
use crate::store::{CANVAS_TILE_POINT, InstalledModule, ModuleExtensionPoint, ModuleTileRef};

pub fn routes() -> Router<AppState> {
    Router::new().route("/modules/canvas-tiles", get(list))
}

/// One `canvas-tile` point the caller may place: `tile` is what a `module` object's `props.tile` names.
#[derive(Serialize)]
struct CanvasTileDto {
    module_id: String,
    tile: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    module: ModuleInfoDto,
}

/// Every `canvas-tile` point of an enabled module whose permission the caller holds. Possibly empty.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CanvasTileDto>>, ApiError> {
    let tiles = reachable_extension_points(&state, ctx.user_id, CANVAS_TILE_POINT)
        .await?
        .into_iter()
        .map(|r| CanvasTileDto {
            module_id: r.module_id,
            tile: r.point.name,
            description: r.point.description,
            module: r.module,
        })
        .collect();
    Ok(Json(tiles))
}

/// The `canvas-tile` point named `tile` in `module`.
pub(super) fn tile_point<'a>(
    module: &'a InstalledModule,
    tile: &str,
) -> Option<&'a ModuleExtensionPoint> {
    module
        .extension_points
        .iter()
        .find(|p| p.kind == CANVAS_TILE_POINT && p.name == tile)
}

/// The module a tile names and the command its point runs, or why it cannot run now.
pub(super) async fn runnable_tile(
    state: &AppState,
    tile: &ModuleTileRef,
) -> Result<(InstalledModule, String), ApiError> {
    let module = state
        .store
        .installed_module(&tile.module_id)
        .await?
        .ok_or(ApiError::Conflict("this tile's module is not installed"))?;
    if !module.enabled {
        return Err(ApiError::Conflict("this tile's module is turned off"));
    }
    super::super::module_compat::require_compatible(&module)?;
    let command = tile_point(&module, &tile.tile)
        .and_then(|p| p.command.clone())
        .ok_or(ApiError::Conflict("this tile's module no longer offers it"))?;
    Ok((module, command))
}

/// Refuses placing a tile the caller could not see offered: the same checks discovery filters on.
pub(super) async fn authorize_place(
    state: &AppState,
    user_id: UserId,
    tile: &ModuleTileRef,
) -> Result<(), ApiError> {
    let (module, _) = runnable_tile(state, tile).await?;
    let permission = tile_point(&module, &tile.tile)
        .and_then(|p| p.permission.as_deref())
        .ok_or(ApiError::Forbidden)?;
    if !state
        .store
        .user_has_module_permission(user_id, &module.id, permission)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}
