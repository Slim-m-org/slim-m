// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /channels/order` for a manager who cannot see every channel: they can
//! reorder what they see, the channels they cannot see keep their place, and
//! nothing in the answer reveals those channels.

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

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-channel-order-hidden");
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

/// A member with a session, built straight through the store. See
/// `tests/channels.rs`'s own copy of this for why it bypasses `/auth/register`.
async fn register(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

async fn setup() -> (Store, support::TestDbGuard, Router, String) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let everyone_id = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap()
        .id;
    for name in ["a", "b"] {
        store.create_channel(name, "text").await.unwrap();
    }
    let hidden = store.create_channel("secret-staff", "text").await.unwrap();
    store.create_channel("c", "text").await.unwrap();
    store
        .set_role_overwrite(
            hidden.id,
            everyone_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let member = register(&store, "bob").await;
    (store, guard, app, member)
}

fn names(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_owned())
        .collect()
}

fn ids(listed: &Value) -> Vec<String> {
    listed
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

async fn channels_of(app: &Router, token: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(token), None))
            .await
            .unwrap(),
    )
    .await
}

async fn put_order(app: &Router, token: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request("PUT", "/channels/order", Some(token), Some(body)))
        .await
        .unwrap();
    (response.status(), json_body(response).await)
}

async fn stored_order(store: &Store) -> Vec<String> {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .map(|c| c.name)
        .collect()
}

#[tokio::test]
async fn a_manager_reorders_what_they_see_and_hidden_channels_keep_their_slot() {
    let (store, _guard, app, token) = setup().await;
    let listed = channels_of(&app, &token).await;
    assert_eq!(names(&listed), ["a", "b", "c"], "GET /channels hides it");

    let mut order = ids(&listed);
    order.reverse();
    let (status, body) = put_order(&app, &token, json!({ "channel_ids": order })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        names(&body),
        ["c", "b", "a"],
        "the answer is what they can list"
    );
    assert_eq!(
        stored_order(&store).await,
        ["c", "b", "secret-staff", "a"],
        "the hidden channel stays at index 2"
    );
}

#[tokio::test]
async fn the_grouped_shape_keeps_hidden_channels_in_place_too() {
    let (store, _guard, app, token) = setup().await;
    let mut order = ids(&channels_of(&app, &token).await);
    order.reverse();
    let body = json!({ "categories": [{ "category_id": null, "channel_ids": order }] });
    let (status, body) = put_order(&app, &token, body).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(names(&body), ["c", "b", "a"]);
    assert_eq!(stored_order(&store).await, ["c", "b", "secret-staff", "a"]);
}

#[tokio::test]
async fn naming_a_channel_the_caller_cannot_see_is_refused_and_changes_nothing() {
    let (store, _guard, app, token) = setup().await;
    let hidden = store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "secret-staff")
        .unwrap()
        .id
        .to_string();
    let mut order = ids(&channels_of(&app, &token).await);
    order.push(hidden);
    let (status, _) = put_order(&app, &token, json!({ "channel_ids": order })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(stored_order(&store).await, ["a", "b", "secret-staff", "c"]);
}

#[tokio::test]
async fn a_partial_list_never_names_a_hidden_channel_as_missing() {
    let (store, _guard, app, token) = setup().await;
    let hidden = store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.name == "secret-staff")
        .unwrap()
        .id
        .to_string();
    let first = ids(&channels_of(&app, &token).await)[..1].to_vec();
    let (status, body) = put_order(&app, &token, json!({ "channel_ids": first })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(!body.to_string().contains(&hidden), "{body}");
}
