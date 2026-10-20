// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin audit log: every successful admin write is recorded by one
//! middleware, keyed on the matched route, and `/space/audit-log` reads it.
//!
//! One table of audited routes instead of a call in each handler, so a new
//! admin route is one line here, and `tests/admin_audit.rs` fails when a
//! mutating route is neither audited nor listed as exempt.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::extract::{FromRequestParts, MatchedPath, Query, RawPathParams, Request, State};
use axum::http::request::Parts;
use axum::http::{Method, header};
use axum::middleware::Next;
use axum::response::Response;
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::AdminAuditEntry;

/// One audited route: its method and axum template, the action it records,
/// and which path parameter names the thing changed. `None` reads the id
/// from the response instead, for creates.
pub struct AuditedRoute {
    pub method: Method,
    pub path: &'static str,
    pub action: &'static str,
    pub target: Option<&'static str>,
}

const fn route(
    method: Method,
    path: &'static str,
    action: &'static str,
    target: Option<&'static str>,
) -> AuditedRoute {
    AuditedRoute {
        method,
        path,
        action,
        target,
    }
}

const CH: Option<&str> = Some("channel_id");
const CAT: Option<&str> = Some("category_id");
const ROLE: Option<&str> = Some("role_id");
const MODULE: Option<&str> = Some("id");

/// Every admin change the log records.
pub const AUDITED_ROUTES: &[AuditedRoute] = &[
    route(Method::PATCH, "/space/settings", "space.update", None),
    route(Method::PUT, "/space/join-gate", "space.join_gate", None),
    route(Method::PATCH, "/space/analytics", "space.analytics", None),
    route(Method::PATCH, "/space/retention", "space.retention", None),
    route(Method::PATCH, "/space/canvas-cap", "space.canvas_cap", None),
    route(
        Method::PATCH,
        "/space/screen-share",
        "space.screen_share",
        None,
    ),
    route(
        Method::PATCH,
        "/space/attachment-limit",
        "space.attachment_limit",
        None,
    ),
    route(
        Method::PATCH,
        "/space/media-compression",
        "space.media_compression",
        None,
    ),
    route(
        Method::PATCH,
        "/space/link-previews",
        "space.link_previews",
        None,
    ),
    route(Method::POST, "/space/icon", "space.icon_set", None),
    route(Method::DELETE, "/space/icon", "space.icon_clear", None),
    route(Method::POST, "/space/banner", "space.banner_set", None),
    route(Method::DELETE, "/space/banner", "space.banner_clear", None),
    route(Method::POST, "/exports/space", "space.export", None),
    route(Method::POST, "/roles", "role.create", None),
    route(Method::PATCH, "/roles/reorder", "role.reorder", None),
    route(Method::PATCH, "/roles/{role_id}", "role.update", ROLE),
    route(Method::DELETE, "/roles/{role_id}", "role.delete", ROLE),
    route(
        Method::PUT,
        "/members/{user_id}/roles/{role_id}",
        "role.assign",
        Some("user_id"),
    ),
    route(
        Method::DELETE,
        "/members/{user_id}/roles/{role_id}",
        "role.unassign",
        Some("user_id"),
    ),
    route(
        Method::PUT,
        "/roles/{role_id}/module-permissions/{module_id}/{perm_key}",
        "role.module_grant",
        ROLE,
    ),
    route(
        Method::DELETE,
        "/roles/{role_id}/module-permissions/{module_id}/{perm_key}",
        "role.module_revoke",
        ROLE,
    ),
    route(Method::POST, "/channels", "channel.create", None),
    route(Method::PUT, "/channels/order", "channel.reorder", None),
    route(
        Method::PATCH,
        "/channels/{channel_id}",
        "channel.update",
        CH,
    ),
    route(
        Method::DELETE,
        "/channels/{channel_id}",
        "channel.delete",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/retention",
        "channel.retention",
        CH,
    ),
    route(
        Method::PATCH,
        "/channels/{channel_id}/room",
        "channel.room",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/overwrites",
        "channel.overwrites",
        CH,
    ),
    route(
        Method::POST,
        "/channels/{channel_id}/overwrites/sync",
        "channel.overwrites_sync",
        CH,
    ),
    route(
        Method::PUT,
        "/channels/{channel_id}/overwrites/{kind}/{id}",
        "channel.overwrite_set",
        CH,
    ),
    route(
        Method::DELETE,
        "/channels/{channel_id}/overwrites/{kind}/{id}",
        "channel.overwrite_clear",
        CH,
    ),
    route(Method::POST, "/categories", "category.create", None),
    route(
        Method::PATCH,
        "/categories/{category_id}",
        "category.update",
        CAT,
    ),
    route(
        Method::DELETE,
        "/categories/{category_id}",
        "category.delete",
        CAT,
    ),
    route(
        Method::PUT,
        "/categories/{category_id}/overwrites",
        "category.overwrites",
        CAT,
    ),
    route(Method::POST, "/invites", "invite.create", None),
    route(
        Method::DELETE,
        "/invites/{code}",
        "invite.revoke",
        Some("code"),
    ),
    route(Method::POST, "/emoji", "emoji.create", None),
    route(Method::POST, "/emoji/bulk", "emoji.bulk_create", None),
    route(
        Method::DELETE,
        "/emoji/{emoji_id}",
        "emoji.delete",
        Some("emoji_id"),
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/install",
        "module.install",
        MODULE,
    ),
    route(
        Method::DELETE,
        "/space/dock/modules/{id}/install",
        "module.uninstall",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/enable",
        "module.enable",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/modules/{id}/disable",
        "module.disable",
        MODULE,
    ),
    route(
        Method::DELETE,
        "/space/dock/modules/{id}/storage",
        "module.clear_storage",
        MODULE,
    ),
    route(
        Method::PUT,
        "/space/dock/modules/{id}/schedule-channel",
        "module.schedule_channel",
        MODULE,
    ),
    route(
        Method::POST,
        "/space/dock/sources",
        "module_source.add",
        None,
    ),
    route(
        Method::DELETE,
        "/space/dock/sources/{sourceId}",
        "module_source.remove",
        Some("sourceId"),
    ),
];

/// Request and response bodies past this are not read for field names or ids.
const MAX_INSPECTED_BODY: usize = 64 * 1024;
const MAX_FIELDS: usize = 32;
const MAX_NAME_CHARS: usize = 100;
const PAGE_DEFAULT: i64 = 50;
const PAGE_MAX: i64 = 200;

pub fn routes() -> Router<AppState> {
    Router::new().route("/space/audit-log", get(list))
}

fn audited(method: &Method, path: &str) -> Option<&'static AuditedRoute> {
    AUDITED_ROUTES
        .iter()
        .find(|route| route.method == method && route.path == path)
}

/// Records the change after the handler succeeds. A failed write to the log
/// is logged and never turns a completed change into an error.
pub async fn record(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let Some(route) = request
        .extensions()
        .get::<MatchedPath>()
        .and_then(|matched| audited(request.method(), matched.as_str()))
    else {
        return next.run(request).await;
    };
    let (mut parts, body) = request.into_parts();
    let actor = Authed::from_request_parts(&mut parts, &state).await.ok();
    let params = path_params(&mut parts, &state).await;
    let (body, request_json) = inspect_json(&parts.headers, body).await;
    let response = next.run(Request::from_parts(parts, body)).await;
    let Some(Authed(ctx)) = actor else {
        return response;
    };
    if !response.status().is_success() {
        return response;
    }
    let (response, target) = match route.target {
        Some(name) => (
            response,
            params.get(name).and_then(Value::as_str).map(str::to_owned),
        ),
        None => created_id(response).await,
    };
    let detail = detail(route, params, request_json.as_ref());
    if let Err(error) = state
        .store
        .record_admin_change(ctx.user_id, route.action, target.as_deref(), &detail)
        .await
    {
        tracing::warn!(%error, action = route.action, "could not record an admin change");
    }
    response
}

async fn path_params(parts: &mut Parts, state: &AppState) -> Map<String, Value> {
    let Ok(raw) = RawPathParams::from_request_parts(parts, state).await else {
        return Map::new();
    };
    raw.iter()
        .map(|(key, value)| (key.to_owned(), Value::from(value)))
        .collect()
}

fn is_json(headers: &axum::http::HeaderMap) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("application/json"))
}

/// Reads a small JSON body so its field names can be logged, and hands back
/// an equivalent body for the handler. Anything else passes through untouched.
async fn inspect_json(headers: &axum::http::HeaderMap, body: Body) -> (Body, Option<Value>) {
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok());
    if !is_json(headers) || declared.is_none_or(|length| length > MAX_INSPECTED_BODY) {
        return (body, None);
    }
    match to_bytes(body, MAX_INSPECTED_BODY).await {
        Ok(bytes) => {
            let json = serde_json::from_slice(&bytes).ok();
            (Body::from(bytes), json)
        }
        Err(_) => (Body::empty(), None),
    }
}

async fn created_id(response: Response) -> (Response, Option<String>) {
    if !is_json(response.headers()) {
        return (response, None);
    }
    let (parts, body) = response.into_parts();
    let Ok(bytes) = to_bytes(body, MAX_INSPECTED_BODY).await else {
        return (Response::from_parts(parts, Body::empty()), None);
    };
    let id = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|json| match json.get("id").or_else(|| json.get("code")) {
            Some(Value::String(id)) => Some(id.clone()),
            Some(Value::Number(id)) => Some(id.to_string()),
            _ => None,
        });
    (Response::from_parts(parts, Body::from(bytes)), id)
}

fn detail(route: &AuditedRoute, mut params: Map<String, Value>, body: Option<&Value>) -> String {
    let mut detail = Map::new();
    if let Some(target) = route.target {
        params.remove(target);
    }
    if !params.is_empty() {
        detail.insert("params".into(), Value::Object(params));
    }
    if let Some(Value::Object(fields)) = body {
        let names: Vec<Value> = fields
            .keys()
            .take(MAX_FIELDS)
            .cloned()
            .map(Value::from)
            .collect();
        if !names.is_empty() {
            detail.insert("fields".into(), Value::Array(names));
        }
        if let Some(Value::String(name)) = fields.get("name") {
            let name: String = name.chars().take(MAX_NAME_CHARS).collect();
            detail.insert("name".into(), Value::from(name));
        }
    }
    Value::Object(detail).to_string()
}

#[derive(Deserialize)]
struct ListQuery {
    before: Option<i64>,
    limit: Option<i64>,
}

#[derive(Serialize)]
struct AdminChangeDto {
    id: i64,
    actor_id: Option<String>,
    action: String,
    target_id: Option<String>,
    detail: Value,
    created_at: i64,
}

impl From<AdminAuditEntry> for AdminChangeDto {
    fn from(entry: AdminAuditEntry) -> Self {
        Self {
            id: entry.id,
            actor_id: entry.actor_id.map(|id| id.to_string()),
            action: entry.action,
            target_id: entry.target_id,
            detail: serde_json::from_str(&entry.detail)
                .unwrap_or_else(|_| Value::Object(Map::new())),
            created_at: entry.created_at,
        }
    }
}

async fn list(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Query(query): Query<ListQuery>,
) -> Result<Json<Vec<AdminChangeDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let limit = query.limit.unwrap_or(PAGE_DEFAULT).clamp(1, PAGE_MAX);
    let entries = state.store.admin_changes(query.before, limit).await?;
    Ok(Json(entries.into_iter().map(Into::into).collect()))
}
