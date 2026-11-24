// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin audit log: every successful admin write is recorded by one
//! middleware, keyed on the matched route, and `/space/audit-log` reads it.
//!
//! One table of audited routes instead of a call in each handler, so a new
//! admin route is one line here, and `tests/it_spaces/admin_audit.rs` fails when a
//! mutating route is neither audited nor listed as exempt.

use axum::Router;
use axum::body::{Body, HttpBody, to_bytes};
use axum::extract::{FromRequestParts, MatchedPath, Query, RawPathParams, Request, State};
use axum::http::request::Parts;
use axum::http::{Method, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::AdminAuditEntry;

mod audited_routes;
mod redaction;

pub use audited_routes::{AUDITED_ROUTES, AuditedRoute};

/// Request and response bodies past this are not read for field names or ids.
const MAX_INSPECTED_BODY: usize = 64 * 1024;
const MAX_FIELDS: usize = 32;
const MAX_NAME_CHARS: usize = 100;
/// Well under the 4096 characters the table's CHECK allows, so a row is never refused for its detail.
const MAX_DETAIL_CHARS: usize = 3500;
/// A replayed write inside this window with the same detail is the same change.
const REPLAY_WINDOW_MS: i64 = 30_000;
const RECORD_ATTEMPTS: u32 = 3;
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
    let (body, request_json, uninspected) = match inspect_json(&parts.headers, body).await {
        Ok(inspected) => inspected,
        Err(refusal) => return refusal,
    };
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
    let mut detail = detail(route, params, request_json.as_ref());
    if uninspected {
        detail = with_uninspected(&detail);
    }
    write_row(&state, route, ctx.user_id, target.as_deref(), &detail).await;
    response
}

/// Whether a repeat of this write inside the replay window is the same change, as for an idempotent PUT or DELETE.
fn is_replayable(method: &Method) -> bool {
    method == Method::PUT || method == Method::DELETE
}

/// Retries a failed insert, then falls back to an empty detail so the action and actor are always kept.
async fn write_row(
    state: &AppState,
    route: &AuditedRoute,
    actor: crate::ids::UserId,
    target: Option<&str>,
    detail: &str,
) {
    let mut last_error = None;
    for attempt in 0..RECORD_ATTEMPTS {
        let detail = if attempt + 1 == RECORD_ATTEMPTS {
            "{}"
        } else {
            detail
        };
        let written = if is_replayable(&route.method) {
            state
                .store
                .record_admin_change_unless_repeated(
                    actor,
                    (route.action, target),
                    detail,
                    REPLAY_WINDOW_MS,
                )
                .await
                .map(drop)
        } else {
            state
                .store
                .record_admin_change(actor, route.action, target, detail)
                .await
        };
        match written {
            Ok(()) => return,
            Err(error) => last_error = Some(error),
        }
    }
    if let Some(error) = last_error {
        tracing::error!(%error, action = route.action, "could not record an admin change");
    }
}

fn with_uninspected(detail: &str) -> String {
    let mut object = match serde_json::from_str(detail) {
        Ok(Value::Object(object)) => object,
        _ => Map::new(),
    };
    object.insert("uninspected".into(), Value::Bool(true));
    Value::Object(object).to_string()
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

/// Reads a small JSON body so its field names can be logged, and hands back an equivalent body for
/// the handler, with whether the body was left unread. A body without a length is buffered up to the
/// cap and refused past it, so leaving out Content-Length hides nothing from the log.
async fn inspect_json(
    headers: &axum::http::HeaderMap,
    body: Body,
) -> Result<(Body, Option<Value>, bool), Response> {
    if !is_json(headers) {
        return Ok((body, None, false));
    }
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok());
    if declared.is_some_and(|length| length > MAX_INSPECTED_BODY) {
        return Ok((body, None, true));
    }
    match to_bytes(body, MAX_INSPECTED_BODY).await {
        Ok(bytes) => {
            let json = serde_json::from_slice(&bytes).ok();
            Ok((Body::from(bytes), json, false))
        }
        Err(_) if declared.is_none() => Err(ApiError::PayloadTooLarge.into_response()),
        Err(_) => Ok((Body::empty(), None, false)),
    }
}

/// Whether the body is known to fit the inspection cap; one that may not is passed through whole.
fn fits_inspection(body: &Body) -> bool {
    HttpBody::size_hint(body)
        .upper()
        .is_some_and(|upper| upper <= MAX_INSPECTED_BODY as u64)
}

async fn created_id(response: Response) -> (Response, Option<String>) {
    if !is_json(response.headers()) || !fits_inspection(response.body()) {
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
        let params = params
            .into_iter()
            .map(|(key, value)| (clip(&key), clip_value(value)))
            .collect();
        detail.insert("params".into(), Value::Object(params));
    }
    if let Some(Value::Object(fields)) = body {
        let names: Vec<Value> = fields
            .keys()
            .take(MAX_FIELDS)
            .map(|name| Value::from(clip(name)))
            .collect();
        if !names.is_empty() {
            detail.insert("fields".into(), Value::Array(names));
        }
        if let Some(Value::String(name)) = fields.get("name") {
            detail.insert("name".into(), Value::from(clip(name)));
        }
        if route.action == "bot.prefix"
            && let Some(Value::String(prefix)) = fields.get("prefix")
        {
            detail.insert("prefix".into(), Value::from(clip(prefix.trim())));
        }
        if route.action == "module.install" || route.action == "module.install_file" {
            insert_approvals(&mut detail, fields);
        }
    }
    bounded(detail)
}

fn clip(text: &str) -> String {
    text.chars().take(MAX_NAME_CHARS).collect()
}

fn clip_value(value: Value) -> Value {
    match value {
        Value::String(text) => Value::from(clip(&text)),
        other => other,
    }
}

/// Drops the least important keys until the serialized detail fits, so the insert can never fail its CHECK.
fn bounded(mut detail: Map<String, Value>) -> String {
    for key in ["fields", "params", "approved", "prefix", "name"] {
        let text = Value::Object(detail.clone()).to_string();
        if text.chars().count() <= MAX_DETAIL_CHARS {
            return text;
        }
        detail.remove(key);
    }
    let text = Value::Object(detail).to_string();
    if text.chars().count() <= MAX_DETAIL_CHARS {
        text
    } else {
        "{}".to_owned()
    }
}

/// Which host capabilities an install approved, and whether it also approved local network access,
/// so the log says what an admin granted and not only that they installed.
fn insert_approvals(detail: &mut Map<String, Value>, body: &Map<String, Value>) {
    if let Some(Value::Array(approved)) = body.get("approved_host_capabilities") {
        let names: Vec<Value> = approved
            .iter()
            .filter_map(Value::as_str)
            .take(MAX_FIELDS)
            .map(|name| Value::from(clip(name)))
            .collect();
        detail.insert("approved".into(), Value::Array(names));
    }
    if body.get("approve_local_network") == Some(&Value::Bool(true)) {
        detail.insert("local_network".into(), Value::Bool(true));
    }
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

const INVITE_CODE_PREFIX_CHARS: usize = 4;

/// A live invite code is a bearer credential and this log needs only MANAGE_SERVER.
fn redact_invite_code(action: &str, target: Option<String>) -> Option<String> {
    if !action.starts_with("invite.") {
        return target;
    }
    target.map(|code| {
        let prefix: String = code.chars().take(INVITE_CODE_PREFIX_CHARS).collect();
        format!("{prefix}...")
    })
}

impl From<AdminAuditEntry> for AdminChangeDto {
    fn from(entry: AdminAuditEntry) -> Self {
        Self {
            id: entry.id,
            actor_id: entry.actor_id.map(|id| id.to_string()),
            target_id: redact_invite_code(&entry.action, entry.target_id),
            action: entry.action,
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
    let mut changes: Vec<AdminChangeDto> = entries.into_iter().map(Into::into).collect();
    redaction::redact_hidden(&state, ctx.user_id, &mut changes).await?;
    Ok(Json(changes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn install_route() -> &'static AuditedRoute {
        AUDITED_ROUTES
            .iter()
            .find(|r| r.action == "module.install")
            .unwrap()
    }

    fn detail_of(route: &AuditedRoute, body: &Value) -> Value {
        serde_json::from_str(&detail(route, Map::new(), Some(body))).unwrap()
    }

    #[test]
    fn an_install_records_what_the_admin_approved_and_not_the_version_text() {
        let body = json!({
            "version": "0.2.0",
            "approved_host_capabilities": ["data.store", "message.post"],
            "approve_local_network": true,
            "reviewed_digest": "abc",
        });
        let detail = detail_of(install_route(), &body);
        assert_eq!(detail["approved"], json!(["data.store", "message.post"]));
        assert_eq!(detail["local_network"], json!(true));
        assert!(detail.get("version").is_none() && detail.get("reviewed_digest").is_none());
    }

    #[test]
    fn an_install_that_approves_nothing_says_so_and_one_that_omits_it_says_nothing() {
        let none = detail_of(
            install_route(),
            &json!({"version": "1", "approved_host_capabilities": []}),
        );
        assert_eq!(none["approved"], json!([]));
        let omitted = detail_of(install_route(), &json!({"version": "1"}));
        assert!(omitted.get("approved").is_none());
    }

    #[test]
    fn approvals_are_only_read_for_an_install_and_are_bounded() {
        let body = json!({"approved_host_capabilities": ["x".repeat(500)]});
        let other = AUDITED_ROUTES
            .iter()
            .find(|r| r.action == "module.enable")
            .unwrap();
        assert!(detail_of(other, &body).get("approved").is_none());
        let long = detail_of(install_route(), &body);
        assert_eq!(
            long["approved"][0].as_str().unwrap().chars().count(),
            MAX_NAME_CHARS
        );
    }
}
