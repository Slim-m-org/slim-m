// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Role.hoist` over `PATCH /roles/{roleId}`, and the top hoisted role that
//! `GET /members` reports for the member pane's sections.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

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

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store; see
/// `tests/roles.rs`'s identical helper for why this skips `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn create_role(app: &Router, token: &str, name: &str) -> String {
    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(token),
                Some(json!({ "name": name, "permissions": 0 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    created["id"].as_str().unwrap().to_owned()
}

async fn set_hoist(app: &Router, token: &str, role_id: &str, hoist: bool) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/roles/{role_id}"),
                Some(token),
                Some(json!({ "hoist": hoist })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn member(app: &Router, token: &str, user_id: &str) -> Value {
    let members = json_body(
        app.clone()
            .oneshot(request("GET", "/members", Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == user_id)
        .unwrap()
        .clone()
}

/// Off at creation, toggled on its own without resending other fields, and
/// the response and `GET /roles` agree.
#[tokio::test]
async fn hoist_defaults_off_and_toggles_on_its_own() {
    let (store, _guard) = support::new_store("slimm-role-hoist").await;
    let app = app(store.clone());
    let (token, _) = register(&store, "alice").await;
    let role_id = create_role(&app, &token, "Core Team").await;

    let roles = json_body(
        app.clone()
            .oneshot(request("GET", "/roles", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let listed = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == role_id.as_str());
    assert_eq!(listed.unwrap()["hoist"], false);

    let on = set_hoist(&app, &token, &role_id, true).await;
    assert_eq!(on["hoist"], true);
    assert_eq!(on["name"], "Core Team");
    assert_eq!(
        set_hoist(&app, &token, &role_id, false).await["hoist"],
        false
    );
}

#[tokio::test]
async fn hoist_needs_manage_roles_and_a_real_role() {
    let (store, _guard) = support::new_store("slimm-role-hoist").await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "alice").await;
    let role_id = create_role(&app, &admin, "Core Team").await;
    let plain = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let plain_token = store
        .open_session(plain.id, "cli")
        .await
        .unwrap()
        .access_token;

    let denied = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{role_id}"),
            Some(&plain_token),
            Some(json!({ "hoist": true })),
        ))
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);
    assert_eq!(
        member(&app, &admin, &plain.id.to_string()).await["hoisted_role_id"],
        Value::Null
    );

    let missing = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{}", uuid::Uuid::now_v7()),
            Some(&admin),
            Some(json!({ "hoist": true })),
        ))
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::NOT_FOUND);
}

/// A member's top role is not necessarily the one they are listed under: only
/// a hoisted role counts, the highest of those wins, and the position rides along.
#[tokio::test]
async fn members_report_their_top_hoisted_role_and_its_position() {
    let (store, _guard) = support::new_store("slimm-role-hoist").await;
    let app = app(store.clone());
    let (admin, _) = register(&store, "alice").await;
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let bob_id = bob.id.to_string();
    let top = create_role(&app, &admin, "Top").await;
    let middle = create_role(&app, &admin, "Middle").await;
    let low = create_role(&app, &admin, "Low").await;
    for id in [&top, &middle, &low] {
        store
            .assign_role(
                bob.id,
                id.parse::<uuid::Uuid>()
                    .map(slimm_server::ids::RoleId)
                    .unwrap(),
            )
            .await
            .unwrap();
    }

    let roles = json_body(
        app.clone()
            .oneshot(request("GET", "/roles", Some(&admin), None))
            .await
            .unwrap(),
    )
    .await;
    let mut order: Vec<String> = roles
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["is_everyone"] == false)
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .filter(|id| ![&top, &middle, &low].contains(&id))
        .collect();
    order.extend([top.clone(), middle.clone(), low.clone()]);
    let reordered = app
        .clone()
        .oneshot(request(
            "PATCH",
            "/roles/reorder",
            Some(&admin),
            Some(json!({ "role_ids": order })),
        ))
        .await
        .unwrap();
    assert_eq!(reordered.status(), StatusCode::OK);
    let positions = json_body(reordered).await;
    let position_of = |id: &str| {
        positions
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap()["position"]
            .clone()
    };

    let before = member(&app, &admin, &bob_id).await;
    assert_eq!(before["hoisted_role_id"], Value::Null);
    assert_eq!(before["hoisted_role_position"], Value::Null);

    set_hoist(&app, &admin, &low, true).await;
    let only_low = member(&app, &admin, &bob_id).await;
    assert_eq!(only_low["hoisted_role_id"], low.as_str());
    assert_eq!(only_low["hoisted_role_position"], position_of(&low));

    set_hoist(&app, &admin, &middle, true).await;
    let both = member(&app, &admin, &bob_id).await;
    assert_eq!(both["hoisted_role_id"], middle.as_str());
    assert_eq!(both["hoisted_role_position"], position_of(&middle));
    assert_eq!(
        both["role_ids"][0],
        top.as_str(),
        "the unhoisted top role still leads role_ids"
    );
}
