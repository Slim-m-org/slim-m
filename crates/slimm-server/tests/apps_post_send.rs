// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An app launch is a message send underneath, so it must do what a send does
//! after the permission check: honour slow mode, advance the author's own read
//! marker, and tell a thread's parent its reply count moved. The controls pin
//! the same three behaviours on a plain send.
//!
//! The setup mirrors `tests/apps.rs`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::{Event, Hub};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    Store, User,
};
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

async fn store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store) -> Router {
    app_with_hub(store, Hub::new())
}

fn app_with_hub(store: Store, hub: Hub) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub,
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

/// The launcher: a member who clears VIEW_CHANNEL and SEND_MESSAGES through the
/// default `everyone` role. That role carries no module permission, so a
/// launch's module gate (decision 0021) is exercised on its own.
async fn member(s: &Store) -> User {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    s.create_user("nia", "Nia").await.unwrap()
}

/// Installs `widget` with a `surf` command and an `app` extension point that
/// launches it, both gated on the `play` permission.
async fn install(s: &Store, enabled: bool) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    s.install_module(InstallModuleRequest {
        id: "widget",
        name: "Widget",
        version: "0.1.0",
        artifact_sha256: &sha256,
        approved_capabilities: &[],
        runtime_limits: &ModuleRuntimeLimits::default(),
        permissions: &[ModulePermissionSpec {
            key: "play",
            name: "Play the widget",
            description: "launch and play it",
        }],
        extension_points: &[
            ModuleExtensionPointSpec {
                kind: "command",
                name: "surf",
                description: Some("draws a surface"),
                permission: Some("play"),
                command: None,
                language: None,
            },
            ModuleExtensionPointSpec {
                kind: "app",
                name: "Widget",
                description: Some("Launch the widget in chat"),
                permission: Some("play"),
                command: Some("surf"),
                language: None,
            },
        ],
    })
    .await
    .unwrap();
    s.store_module_artifact("widget", &sha256, &wasm)
        .await
        .unwrap();
    if enabled {
        s.set_module_enabled("widget", true).await.unwrap();
    }
}

/// Grants `widget:play` to a fresh role and assigns it to `user`.
async fn grant_play(s: &Store, user: &User) {
    let role = s
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, "widget", "play")
        .await
        .unwrap();
}

fn post(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn launch(channel: &str, token: &str, caption: &str) -> Request<Body> {
    launch_with_id(channel, token, caption, &Uuid::now_v7().to_string())
}

fn launch_with_id(channel: &str, token: &str, caption: &str, id: &str) -> Request<Body> {
    post(
        &format!("/channels/{channel}/messages/apps"),
        token,
        json!({
            "id": id,
            "content": caption,
            "module_id": "widget",
            "command": "surf",
        }),
    )
}

fn plain(channel: &str, token: &str) -> Request<Body> {
    post(
        &format!("/channels/{channel}/messages"),
        token,
        json!({"id": Uuid::now_v7().to_string(), "content": "plain"}),
    )
}

fn drain(rx: &mut tokio::sync::broadcast::Receiver<Event>) -> (bool, bool) {
    let (mut read, mut thread) = (false, false);
    while let Ok(ev) = rx.try_recv() {
        match ev {
            Event::ReadStateChanged { .. } => read = true,
            Event::ThreadUpdated { .. } => thread = true,
            _ => {}
        }
    }
    (read, thread)
}

async fn open_thread(router: &Router, channel: &str, tok: &str) -> String {
    let root = Uuid::now_v7().to_string();
    let sent = router
        .clone()
        .oneshot(post(
            &format!("/channels/{channel}/messages"),
            tok,
            json!({"id": root, "content": "root"}),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let opened = router
        .clone()
        .oneshot(post(
            &format!("/channels/{channel}/messages/{root}/thread"),
            tok,
            json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(opened.status(), StatusCode::OK);
    json_body(opened).await["id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn control_plain_send_does_all_three_things() {
    let (s, _guard) = store("slimm-apps-post-send-control").await;
    let user = member(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.update_channel_slow_mode(channel.id, 60).await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let hub = Hub::new();
    let router = app_with_hub(s, hub.clone());
    let mut rx = hub.subscribe();
    let c = channel.id.to_string();
    assert_eq!(
        router
            .clone()
            .oneshot(plain(&c, tok))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    assert!(
        drain(&mut rx).0,
        "control: a plain send advances the read marker"
    );
    assert_eq!(
        router
            .clone()
            .oneshot(plain(&c, tok))
            .await
            .unwrap()
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
}

#[tokio::test]
async fn control_plain_thread_reply_updates_the_parent() {
    let (s, _guard) = store("slimm-apps-post-send-control2").await;
    let user = member(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let hub = Hub::new();
    let router = app_with_hub(s, hub.clone());
    let thread_id = open_thread(&router, &channel.id.to_string(), tok).await;
    let mut rx = hub.subscribe();
    assert_eq!(
        router
            .clone()
            .oneshot(plain(&thread_id, tok))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    assert!(
        drain(&mut rx).1,
        "control: a plain thread reply publishes ThreadUpdated"
    );
}

#[tokio::test]
async fn app_launch_respects_slow_mode() {
    let (s, _guard) = store("slimm-apps-post-send-slow").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.update_channel_slow_mode(channel.id, 60).await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let router = app(s);
    let c = channel.id.to_string();
    let a = router.clone().oneshot(launch(&c, tok, "a")).await.unwrap();
    assert_eq!(a.status(), StatusCode::OK);
    let b = router.clone().oneshot(launch(&c, tok, "b")).await.unwrap();
    assert_eq!(
        b.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "second app launch inside a 60s slow mode window"
    );
}

#[tokio::test]
async fn app_launch_advances_the_authors_read_marker() {
    let (s, _guard) = store("slimm-apps-post-send-read").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let hub = Hub::new();
    let router = app_with_hub(s, hub.clone());
    let mut rx = hub.subscribe();
    let r = router
        .oneshot(launch(
            &channel.id.to_string(),
            token.access_token.as_str(),
            "x",
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    assert!(
        drain(&mut rx).0,
        "launching an app must advance the author's own read marker like a send does"
    );
}

#[tokio::test]
async fn app_launch_in_a_thread_updates_the_parent_reply_count() {
    let (s, _guard) = store("slimm-apps-post-send-thread").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let hub = Hub::new();
    let router = app_with_hub(s, hub.clone());
    let thread_id = open_thread(&router, &channel.id.to_string(), tok).await;
    let mut rx = hub.subscribe();
    let r = router
        .clone()
        .oneshot(launch(&thread_id, tok, "x"))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    assert!(
        drain(&mut rx).1,
        "an app launched in a thread must publish ThreadUpdated for the parent"
    );
}

#[tokio::test]
async fn a_retried_app_launch_is_not_refused_by_slow_mode() {
    let (s, _guard) = store("slimm-apps-post-send-retry").await;
    let user = member(&s).await;
    install(&s, true).await;
    grant_play(&s, &user).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.update_channel_slow_mode(channel.id, 60).await.unwrap();
    let token = s.open_session(user.id, "phone").await.unwrap();
    let tok = token.access_token.as_str();
    let router = app(s);
    let c = channel.id.to_string();
    let id = Uuid::now_v7().to_string();
    let first = router
        .clone()
        .oneshot(launch_with_id(&c, tok, "a", &id))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let retry = router
        .clone()
        .oneshot(launch_with_id(&c, tok, "a", &id))
        .await
        .unwrap();
    assert_eq!(
        retry.status(),
        StatusCode::OK,
        "an idempotent retry inside the window"
    );
}
