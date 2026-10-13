// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /channels/{channel_id}/thread-parent`, split out of `threads.rs` for
//! the file budget: a cold-opened thread panel's own lookup, keyed only on
//! the thread's own channel id, since it never went through `openThread` on
//! this device and so never learned its parent any other way. Covers the
//! existence-masking rule and the parent message's own content, author and
//! deleted state, which the panel now renders rather than only the AppBar
//! title.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
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
    let auth = Auth::new(2).expect("auth service");
    http::router(AppState {
        store,
        auth,
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

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
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

/// Registers an account and returns its id and access token. The first call
/// claims the deployment (`bootstrap_deployment`) and becomes its
/// administrator, seeding the `general` channel these tests reuse; every
/// later call finds the deployment already claimed and joins as a plain
/// `@everyone` member.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id.to_string(), token)
}

async fn send(app: &Router, uri: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                uri,
                token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn open_thread(app: &Router, messages: &str, message_id: &str, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("{messages}/{message_id}/thread"),
                token,
                None,
            ))
            .await
            .unwrap(),
    )
    .await
}

/// `GET /channels/{channel_id}/thread-parent`: a cold-opened thread panel's
/// own lookup, keyed only on the thread's own channel id. Bob never opens
/// the thread himself here; only the parent's own VIEW_CHANNEL is what has
/// to carry him through.
#[tokio::test]
async fn thread_parent_route_answers_the_real_parent_for_a_viewer() {
    let (store, _guard) = new_store("slimm-threads-parent-route").await;
    let (admin_id, admin) = register(&store, "admin").await;
    let (_bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();

    let answer = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{thread_id}/thread-parent"),
                &bob,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(answer["parent_channel_id"], channel);
    assert_eq!(answer["parent_message_id"], parent_id);
    assert_eq!(answer["parent_channel_name"], "general");
    assert_eq!(answer["parent_content"], "root");
    assert_eq!(answer["parent_deleted"], false);
    assert_eq!(answer["parent_author_id"], admin_id);
    assert_eq!(answer["parent_author_display_name"], "admin");
}

/// The parent message can be soft-deleted independently of its thread, which
/// stays open (its replies live in a separate channel) - so the route must
/// say so rather than sending stale content or masking the whole answer.
#[tokio::test]
async fn thread_parent_route_marks_a_deleted_parent() {
    let (store, _guard) = new_store("slimm-threads-parent-deleted").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();

    let deletion = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("{messages}/{parent_id}"),
            &admin,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deletion.status(), StatusCode::NO_CONTENT);

    let answer = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{thread_id}/thread-parent"),
                &admin,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(answer["parent_channel_id"], channel);
    assert_eq!(answer["parent_message_id"], parent_id);
    assert_eq!(answer["parent_deleted"], true);
    assert!(answer["parent_content"].is_null());
    assert!(answer["parent_author_id"].is_null());
    assert!(answer["parent_author_display_name"].is_null());
}

/// An ordinary, non-thread channel answers all-null, the same shape as one
/// the caller cannot view - never a distinguishable "not a thread" error.
#[tokio::test]
async fn thread_parent_route_answers_all_null_for_an_ordinary_channel() {
    let (store, _guard) = new_store("slimm-threads-parent-not-a-thread").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();

    let answer = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel}/thread-parent"),
                &admin,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(answer["parent_channel_id"].is_null());
    assert!(answer["parent_channel_name"].is_null());
    assert!(answer["parent_message_id"].is_null());
    assert!(answer["parent_content"].is_null());
    assert_eq!(answer["parent_deleted"], false);
    assert!(answer["parent_author_id"].is_null());
    assert!(answer["parent_author_display_name"].is_null());
}

/// The same existence-masking rule `getChannelPermissions` already applies:
/// a thread the caller cannot view answers identically to one that does not
/// exist, so this route cannot become a second channel-existence oracle.
#[tokio::test]
async fn thread_parent_route_masks_a_thread_the_caller_cannot_view() {
    let (store, _guard) = new_store("slimm-threads-parent-masked").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let (bob_id, bob) = register(&store, "bob").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let parent = send(&app, &messages, &admin, "root").await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();

    let overwrite_uri = format!("/channels/{channel}/overwrites/member/{bob_id}");
    app.clone()
        .oneshot(request(
            "PUT",
            &overwrite_uri,
            &admin,
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();

    let masked = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{thread_id}/thread-parent"),
                &bob,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(masked["parent_channel_id"].is_null());
    assert!(masked["parent_channel_name"].is_null());
    assert!(masked["parent_message_id"].is_null());
    assert!(masked["parent_content"].is_null());
    assert_eq!(masked["parent_deleted"], false);
    assert!(masked["parent_author_id"].is_null());
    assert!(masked["parent_author_display_name"].is_null());

    let fabricated = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/thread-parent", Uuid::now_v7()),
                &bob,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        masked, fabricated,
        "a real thread bob cannot view must answer byte-identically to a fabricated id"
    );
}

/// The thread panel shows what the thread is about, attachments included, so
/// the parent's attachments ride the same answer as its text.
#[tokio::test]
async fn thread_parent_route_carries_the_parents_attachments() {
    let (store, _guard) = new_store("slimm-threads-parent-attachments").await;
    let (_admin_id, admin) = register(&store, "admin").await;
    let app = app(store.clone());
    let channel = store.list_channels().await.unwrap()[0].id.to_string();
    let messages = format!("/channels/{channel}/messages");

    let png = b"\x89PNG\r\n\x1a\nparent-picture".to_vec();
    let uploaded = json_body(
        app.clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/attachments?filename=shot.png")
                    .header("authorization", format!("Bearer {admin}"))
                    .body(Body::from(png))
                    .unwrap(),
            )
            .await
            .unwrap(),
    )
    .await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let parent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &messages,
                &admin,
                Some(json!({
                    "id": Uuid::now_v7().to_string(),
                    "content": "look at this",
                    "attachment_ids": [attachment_id.clone()],
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let parent_id = parent["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, &messages, &parent_id, &admin).await;
    let thread_id = thread["id"].as_str().unwrap().to_owned();

    let answer = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{thread_id}/thread-parent"),
                &admin,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let attachments = answer["parent_attachments"].as_array().unwrap();
    assert_eq!(attachments.len(), 1);
    assert_eq!(attachments[0]["id"], attachment_id);
    assert_eq!(attachments[0]["filename"], "shot.png");
    assert_eq!(attachments[0]["content_type"], "image/png");
}
