// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every documented route, called with a disabled connector's token and with one approved
//! no bits: the disabled one reaches nothing, and the other reaches only the routes a
//! connector needs whatever it was approved (decision 0090, review of 2026-11-23).

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ratelimit::RateLimiter;
use uuid::Uuid;

const SEND: i64 = slimm_server::permissions::Permissions::VIEW_CHANNEL.bits()
    | slimm_server::permissions::Permissions::SEND_MESSAGES.bits();

use super::harness::{ID, World, world};
use crate::support::app::call;

/// What a connector approved nothing may still do: read itself, open its socket and register
/// what its commands are, and read the directory a bot library starts from.
const WITHOUT_BITS: &[(&str, &str)] = &[
    ("GET", "/connectors/me"),
    ("GET", "/me"),
    ("POST", "/auth/ws-ticket"),
    ("PUT", "/bots/commands"),
    ("PUT", "/bots/ui"),
];

/// Routes that answer anyone, signed in or not, so a token changes nothing.
const PUBLIC: &[(&str, &str)] = &[
    ("GET", "/healthz"),
    ("GET", "/version"),
    ("GET", "/invites/{code}/check"),
];

/// `(method, path)` for every operation in the API contract.
fn documented_routes() -> Vec<(String, String)> {
    let schema = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../schema/openapi.yaml"
    ))
    .unwrap();
    let mut routes = Vec::new();
    let mut path: Option<String> = None;
    for line in schema.lines() {
        if line.starts_with("components:") {
            break;
        }
        if let Some(p) = line.strip_prefix("  /").and_then(|p| p.strip_suffix(':')) {
            path = Some(format!("/{p}"));
            continue;
        }
        let method = line.trim_start_matches("    ").trim_end_matches(':');
        if line.starts_with("    ")
            && !line.starts_with("     ")
            && ["get", "post", "put", "patch", "delete"].contains(&method)
            && let Some(p) = &path
        {
            routes.push((method.to_ascii_uppercase(), p.clone()));
        }
    }
    let order = |m: &str, p: &str| match (m, p) {
        (_, "/auth/logout" | "/account") => 6,
        ("GET", _) => 0,
        ("PUT", _) => 1,
        ("PATCH", _) => 2,
        ("POST", _) => 3,
        _ => 5,
    };
    routes.sort_by_key(|(m, p)| (order(m, p), p.clone()));
    routes
}

/// A concrete URL for a documented path: real ids where the world has them, fresh ones elsewhere.
fn concrete(path: &str, ids: &[(&str, String)]) -> String {
    let mut out = String::new();
    for segment in path.split('/').skip(1) {
        out.push('/');
        match segment.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
            Some(name) => {
                let known = ids.iter().find(|(n, _)| *n == name).map(|(_, v)| v.clone());
                out.push_str(&known.unwrap_or_else(|| Uuid::now_v7().to_string()));
            }
            None => out.push_str(segment),
        }
    }
    out
}

/// Each route with a fresh limiter, so no budget hides an answer; the ones that succeeded.
async fn reachable(w: &World, token: &str, ids: &[(&str, String)]) -> Vec<(String, String)> {
    let mut reached = Vec::new();
    for (method, path) in documented_routes() {
        let mut state = w.state.clone();
        state.limiter = RateLimiter::new();
        let router = slimm_server::http::router(state);
        let body = (method != "GET" && method != "DELETE").then(|| json!({}));
        let (status, answer) =
            call(&router, &method, &concrete(&path, ids), Some(token), body).await;
        if status.is_success() && !PUBLIC.contains(&(method.as_str(), path.as_str())) {
            reached.push((method.clone(), path.clone()));
        }
        assert_ne!(
            status,
            StatusCode::INTERNAL_SERVER_ERROR,
            "{method} {path}: {answer}"
        );
    }
    reached
}

async fn ids(w: &World) -> Vec<(&'static str, String)> {
    let principal = w
        .store
        .installed_module(ID)
        .await
        .unwrap()
        .unwrap()
        .bot_user_id
        .unwrap();
    let general = w.general().await;
    let message = Uuid::now_v7().to_string();
    let body = json!({"id": message, "content": "hello"});
    let (status, _) = w
        .as_owner("POST", &format!("/channels/{general}/messages"), Some(body))
        .await;
    assert!(status.is_success());
    vec![
        ("channelId", general),
        ("userId", w.owner.id.to_string()),
        ("memberId", w.owner.id.to_string()),
        ("messageId", message),
        ("botId", principal.to_string()),
        ("id", ID.to_owned()),
    ]
}

#[tokio::test]
async fn a_disabled_connector_reaches_no_route() {
    let w = world("slimm-conn-walk-off", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    let ids = ids(&w).await;
    w.set_enabled(false).await;
    let reached = reachable(&w, &token, &ids).await;
    assert_eq!(reached, Vec::<(String, String)>::new());
}

#[tokio::test]
async fn a_connector_approved_nothing_reaches_only_what_every_connector_needs() {
    let w = world("slimm-conn-walk-none", &["view_channel", "send_messages"]).await;
    let token = w.installed(0).await;
    let ids = ids(&w).await;
    let reached = reachable(&w, &token, &ids).await;
    let unexpected: Vec<_> = reached
        .iter()
        .filter(|(m, p)| !WITHOUT_BITS.contains(&(m.as_str(), p.as_str())))
        .collect();
    assert!(
        unexpected.is_empty(),
        "a connector approved nothing reached {unexpected:?}"
    );
}
