// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /modules/panels`: the Dock panels a caller may open (decision 0132).
//!
//! A panel is a `command` hosted as a persistent surface beside the chat. It
//! is run through the ordinary per-caller command route, so this file only
//! answers which panels exist for whom, exactly as `GET /modules/apps` does for
//! apps. A deployment with no module declaring a panel answers an empty list.

use axum::Router;
use axum::extract::State;
use axum::routing::get;
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::module_commands::{ModuleInfoDto, reachable_extension_points};

/// The extension-point kind a panel is declared with.
pub(super) const PANEL_KIND: &str = "panel";
/// The add-on API level that introduced panels.
pub(super) const PANEL_API: u32 = 6;

pub fn routes() -> Router<AppState> {
    Router::new().route("/modules/panels", get(list_panels))
}

/// One panel a caller may open: the command its surface runs and the label the
/// apps menu shows.
#[derive(Serialize)]
struct PanelDto {
    module_id: String,
    command: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    module: ModuleInfoDto,
}

async fn list_panels(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<PanelDto>>, ApiError> {
    let panels = reachable_extension_points(&state, ctx.user_id, PANEL_KIND)
        .await?
        .into_iter()
        // A level 5 host stored an unknown kind and ignored it; such a module never asked for a panel.
        .filter(|r| r.addon_api >= PANEL_API)
        .map(|r| PanelDto {
            module_id: r.module_id,
            command: r.command,
            name: r.point.name,
            description: r.point.description,
            module: r.module,
        })
        .collect();
    Ok(Json(panels))
}
