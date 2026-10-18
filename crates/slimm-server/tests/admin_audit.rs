// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The admin audit log: admin writes are recorded by route, failed or
//! forbidden ones are not, `/space/audit-log` is for MANAGE_SERVER only, and
//! no mutating route escapes classification.

use std::path::Path;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::admin_audit::AUDITED_ROUTES;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{Store, User};
use tower::ServiceExt;

mod support;

use support::openapi::{Method, extract_router_routes};

/// Mutating routes that are not admin changes to the space. Member moderation
/// is in `moderation_audit_log`; the rest act on the caller's own things or on
/// content, never on how the space is set up.
const EXEMPT_PREFIXES: &[&str] = &[
    "/account",
    "/admin/",
    "/apps",
    "/attachments",
    "/auth/",
    "/blocks",
    "/bots",
    "/calls",
    "/channels/{channel_id}/canvas",
    "/channels/{channel_id}/messages",
    "/channels/{channel_id}/notification",
    "/channels/{channel_id}/pins",
    "/channels/{channel_id}/read",
    "/channels/{channel_id}/threads",
    "/channels/{channel_id}/typing",
    "/channels/{channel_id}/voice",
    "/channels/{channel_id}/unread",
    "/channels/{channelId}/",
    "/devices",
    "/dms",
    "/gifs",
    "/interactions",
    "/invites/{code}/redeem",
    "/me",
    "/notification",
    "/members/bulk",
    "/members/{user_id}/account",
    "/members/{user_id}/nickname",
    "/members/{user_id}/removal",
    "/members/{user_id}/timeout",
    "/messages",
    "/modules/",
    "/polls",
    "/presence",
    "/push",
    "/read-states",
    "/reports",
    "/saved",
    "/space/rules/accept",
    "/sync",
    "/totp",
    "/uploads",
    "/users",
    "/voice",
    "/webhooks",
];

#[test]
fn every_mutating_route_is_audited_or_exempt() {
    let routes = extract_router_routes(Path::new(env!("CARGO_MANIFEST_DIR")));
    let mut missing = Vec::new();
    for route in &routes {
        if matches!(route.method, Method::Get) {
            continue;
        }
        let audited = AUDITED_ROUTES
            .iter()
            .any(|a| a.method.as_str() == route.method.as_str() && a.path == route.path);
        let exempt = EXEMPT_PREFIXES.iter().any(|p| route.path.starts_with(p));
        if !audited && !exempt {
            missing.push(format!("{} {}", route.method.as_str(), route.path));
        }
    }
    assert!(
        missing.is_empty(),
        "add these to AUDITED_ROUTES (http/admin_audit.rs) or EXEMPT_PREFIXES here:\n{}",
        missing.join("\n")
    );
}

#[test]
fn every_audited_route_is_a_real_route() {
    let routes = extract_router_routes(Path::new(env!("CARGO_MANIFEST_DIR")));
    for audited in AUDITED_ROUTES {
        assert!(
            routes
                .iter()
                .any(|r| r.method.as_str() == audited.method.as_str() && r.path == audited.path),
            "{} {} is audited but not served",
            audited.method,
            audited.path
        );
    }
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn call(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(body) => {
            let bytes = body.to_string();
            builder
                .header("content-type", "application/json")
                .header("content-length", bytes.len())
                .body(Body::from(bytes))
                .unwrap()
        }
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn deployment(s: &Store) -> (User, User) {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

async fn audit_log(router: &Router, token: &str) -> Vec<Value> {
    let response = router
        .clone()
        .oneshot(call("GET", "/space/audit-log", token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await.as_array().unwrap().clone()
}

#[tokio::test]
async fn a_create_and_a_rename_are_recorded_with_their_target() {
    let (s, _guard) = support::new_store("slimm-admin-audit-record").await;
    let (admin, _member) = deployment(&s).await;
    let token = s
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let router = app(s);

    let created = router
        .clone()
        .oneshot(call(
            "POST",
            "/roles",
            &token,
            Some(json!({ "name": "mods", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert!(created.status().is_success(), "{}", created.status());
    let role_id = json_body(created).await["id"].as_str().unwrap().to_owned();

    let renamed = router
        .clone()
        .oneshot(call(
            "PATCH",
            &format!("/roles/{role_id}"),
            &token,
            Some(json!({ "name": "moderators" })),
        ))
        .await
        .unwrap();
    assert!(renamed.status().is_success(), "{}", renamed.status());

    let log = audit_log(&router, &token).await;
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(log[0]["action"], "role.update");
    assert_eq!(log[0]["target_id"], role_id.as_str());
    assert_eq!(log[0]["actor_id"], admin.id.to_string());
    assert_eq!(log[0]["detail"]["fields"], json!(["name"]));
    assert_eq!(log[1]["detail"]["fields"], json!(["name", "permissions"]));
    assert_eq!(log[0]["detail"]["name"], "moderators");
    assert_eq!(log[1]["action"], "role.create");
    assert_eq!(log[1]["target_id"], role_id.as_str());
}

#[tokio::test]
async fn a_refused_write_is_not_recorded_and_members_cannot_read_the_log() {
    let (s, _guard) = support::new_store("slimm-admin-audit-refused").await;
    let (admin, member) = deployment(&s).await;
    let admin_token = s
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let member_token = s
        .open_session(member.id, "phone")
        .await
        .unwrap()
        .access_token;
    let router = app(s);

    let refused = router
        .clone()
        .oneshot(call(
            "POST",
            "/roles",
            &member_token,
            Some(json!({ "name": "mine", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);
    assert!(audit_log(&router, &admin_token).await.is_empty());

    let read = router
        .oneshot(call("GET", "/space/audit-log", &member_token, None))
        .await
        .unwrap();
    assert_eq!(read.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_log_pages_backwards_by_id() {
    let (s, _guard) = support::new_store("slimm-admin-audit-page").await;
    let (admin, _member) = deployment(&s).await;
    for name in ["a", "b", "c"] {
        s.record_admin_change(admin.id, "role.create", Some(name), "{}")
            .await
            .unwrap();
    }
    let token = s
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let router = app(s);

    let first = router
        .clone()
        .oneshot(call("GET", "/space/audit-log?limit=2", &token, None))
        .await
        .unwrap();
    let first = json_body(first).await;
    let first = first.as_array().unwrap();
    assert_eq!(first.len(), 2);
    assert_eq!(first[0]["target_id"], "c");
    let before = first[1]["id"].as_i64().unwrap();
    let rest = router
        .oneshot(call(
            "GET",
            &format!("/space/audit-log?before={before}"),
            &token,
            None,
        ))
        .await
        .unwrap();
    let rest = json_body(rest).await;
    assert_eq!(rest.as_array().unwrap().len(), 1);
    assert_eq!(rest[0]["target_id"], "a");
}
