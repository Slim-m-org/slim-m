// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin's view of what modules hook into, and where they sit in the chain.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::{Deserialize, Serialize};

use crate::http::AppState;
use crate::http::dock::PHASES;
use crate::http::error::ApiError;
use crate::http::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::{HookChange, HookKind};

pub(in crate::http) fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/dock/hooks", get(list))
        .route("/space/dock/modules/{id}/hooks", put(update))
}

/// One hook with its place in the chain and how its module has been doing.
#[derive(Serialize)]
struct HookDto {
    module_id: String,
    module_name: String,
    kind: &'static str,
    hook: String,
    phase: String,
    reads: Vec<String>,
    priority: i64,
    fail_closed: bool,
    /// Whether it is in the chain now: the module is on, in range and approved for it.
    live: bool,
    runs: i64,
    failures: i64,
    last_error: Option<String>,
    last_error_at: Option<i64>,
    last_fuel_used: Option<i64>,
    max_fuel_used: i64,
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<Vec<HookDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let modules = state.store.list_installed_modules().await?;
    let mut stats = state.store.module_run_stats().await?;
    let live = state.dock.hooks().active(&state.store).await;
    let mut hooks = state.store.module_hooks().await?;
    hooks.sort_by_key(|h| {
        let rank = PHASES.iter().position(|p| *p == h.decl.phase).unwrap_or(0);
        (h.decl.kind.as_str(), rank, h.priority)
    });
    let mut out = Vec::with_capacity(hooks.len());
    for hook in hooks {
        let Some(module) = modules.iter().find(|m| m.id == hook.module_id) else {
            continue;
        };
        let command = match hook.decl.kind {
            HookKind::Interceptor => "@intercept",
            HookKind::Permission => "@allow",
        };
        let stat = stats
            .get_mut(&hook.module_id)
            .and_then(|all| all.iter().find(|s| s.command == command).cloned());
        let in_chain = live.as_ref().is_some_and(|snapshot| {
            snapshot
                .interceptors
                .iter()
                .chain(&snapshot.permissions)
                .any(|e| e.module.id == hook.module_id && e.decl == hook.decl)
        });
        out.push(HookDto {
            module_id: module.id.clone(),
            module_name: module.name.clone(),
            kind: hook.decl.kind.as_str(),
            hook: hook.decl.hook,
            phase: hook.decl.phase,
            reads: hook.decl.reads,
            priority: hook.priority,
            fail_closed: hook.fail_closed,
            live: in_chain,
            runs: stat.as_ref().map_or(0, |s| s.run_count),
            failures: stat.as_ref().map_or(0, |s| s.failure_count),
            last_error: stat.as_ref().and_then(|s| s.last_error.clone()),
            last_error_at: stat.as_ref().and_then(|s| s.last_error_at),
            last_fuel_used: stat.as_ref().and_then(|s| s.last_fuel_used),
            max_fuel_used: stat.as_ref().map_or(0, |s| s.max_fuel_used),
        });
    }
    Ok(Json(out))
}

#[derive(Deserialize)]
struct UpdateRequest {
    kind: String,
    hook: String,
    #[serde(default)]
    phase: String,
    priority: Option<i64>,
    fail_closed: Option<bool>,
}

/// Most a priority may be, either way; keeps the order a plain integer sum away from overflow.
const MAX_PRIORITY: i64 = 1_000_000;

async fn update(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Json(req): Json<UpdateRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let kind = match req.kind.as_str() {
        "interceptor" => HookKind::Interceptor,
        "permission" => HookKind::Permission,
        _ => return Err(ApiError::BadRequest("kind is interceptor or permission")),
    };
    if req.priority.is_some_and(|p| p.abs() > MAX_PRIORITY) {
        return Err(ApiError::BadRequest("priority is out of range"));
    }
    let change = HookChange {
        priority: req.priority,
        fail_closed: req.fail_closed,
    };
    let found = state
        .store
        .update_module_hook(&id, (kind, &req.hook, &req.phase), change)
        .await?;
    if !found {
        return Err(ApiError::NotFound("no such hook"));
    }
    Ok(StatusCode::NO_CONTENT)
}
