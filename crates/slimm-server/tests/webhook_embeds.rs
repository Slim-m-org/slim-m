// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /webhooks/{id}/{token}` accepting `embeds`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::link_preview::LinkPreviews;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

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

fn app(store: Store, link_previews: LinkPreviews) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews,
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn post_json(uri: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn bearer_get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// A live administrator and a channel to point a webhook at.
async fn fixture(store: &Store, name: &str) -> (String, ChannelId, UserId) {
    let account = store
        .create_account(name, name, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "text").await.unwrap();
    (token, channel.id, account.id)
}

fn one_embed() -> Value {
    json!({
        "title": "Disk alert",
        "description": "root is 95% full",
        "color": 0xE0_3B3B_i64,
        "fields": [{ "name": "Host", "value": "prod-1", "inline": true }],
    })
}

#[tokio::test]
async fn a_webhook_can_post_an_embed_and_it_renders() {
    let (store, _guard) = new_store("slimm-webhook-embeds-post").await;
    let (viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store, LinkPreviews::disabled());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "disk alert", "embeds": [one_embed()] }),
        ))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);

    let listed = app
        .clone()
        .oneshot(bearer_get(
            &format!("/channels/{channel_id}/messages"),
            &viewer_token,
        ))
        .await
        .unwrap();
    let messages = json_body(listed).await;
    let embeds = messages[0]["embeds"].as_array().unwrap();
    assert_eq!(embeds.len(), 1);
    assert_eq!(embeds[0]["title"], "Disk alert");
    assert_eq!(embeds[0]["accent"], "red");
}

/// Decision 0030's motivating case: an internal snapshot must not block the alert text.
#[tokio::test]
async fn a_webhooks_embed_image_pointed_at_a_blocked_address_is_dropped() {
    let (store, _guard) = new_store("slimm-webhook-embeds-blocked-image").await;
    let (viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let enabled_with_guard = LinkPreviews::new(&Config {
        link_previews: true,
        ..Config::default()
    });
    let app = app(store, enabled_with_guard);

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let mut embed = one_embed();
    embed["image"] = json!({ "url": "http://169.254.169.254/panel.png" });
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "disk alert", "embeds": [embed] }),
        ))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);

    let listed = app
        .clone()
        .oneshot(bearer_get(
            &format!("/channels/{channel_id}/messages"),
            &viewer_token,
        ))
        .await
        .unwrap();
    let messages = json_body(listed).await;
    assert!(messages[0]["embeds"][0]["image_token"].is_null());
    assert_eq!(
        messages[0]["embeds"][0]["title"], "Disk alert",
        "the alert still posts without its image"
    );
}

#[tokio::test]
async fn too_many_embeds_from_a_webhook_is_a_400() {
    let (store, _guard) = new_store("slimm-webhook-embeds-cap").await;
    let (_viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store, LinkPreviews::disabled());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let eleven: Vec<Value> = (0..11).map(|_| one_embed()).collect();
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "spam", "embeds": eleven }),
        ))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::BAD_REQUEST);
}

const OCT_4_NOON_UTC_MS: i64 = 1_791_115_200_000;

/// Posts one embed through a fresh webhook; returns the delivery status and the listed message embeds.
async fn deliver_one_embed(name: &str, embed: Value) -> (StatusCode, Value) {
    let (store, _guard) = new_store(name).await;
    let (viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "sonarr", admin_id)
        .await
        .unwrap();
    let app = app(store, LinkPreviews::disabled());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "grabbed", "embeds": [embed] }),
        ))
        .await
        .unwrap();
    let status = posted.status();
    let listed = app
        .clone()
        .oneshot(bearer_get(
            &format!("/channels/{channel_id}/messages"),
            &viewer_token,
        ))
        .await
        .unwrap();
    (status, json_body(listed).await)
}

/// Discord's own embed `timestamp` is an ISO 8601 string, and Sonarr/Radarr send it.
#[tokio::test]
async fn a_webhook_embed_with_an_iso_timestamp_is_delivered() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-iso-ts",
        json!({ "title": "Episode Grabbed", "timestamp": "2026-10-04T12:00:00.000Z" }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(messages[0]["embeds"][0]["title"], "Episode Grabbed");
    assert_eq!(messages[0]["embeds"][0]["timestamp"], OCT_4_NOON_UTC_MS);
}

#[tokio::test]
async fn a_webhook_embed_with_an_offset_iso_timestamp_is_delivered() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-offset-ts",
        json!({ "title": "Episode Grabbed", "timestamp": "2026-10-04T14:00:00+02:00" }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(messages[0]["embeds"][0]["timestamp"], OCT_4_NOON_UTC_MS);
}

/// A timestamp nobody can read degrades like an unreadable colour or image, never a 400.
#[tokio::test]
async fn a_webhook_embed_with_an_unparseable_timestamp_still_posts() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-bad-ts",
        json!({ "title": "Episode Grabbed", "timestamp": "not a date" }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(messages[0]["embeds"][0]["title"], "Episode Grabbed");
    assert!(messages[0]["embeds"][0]["timestamp"].is_null());
}

#[tokio::test]
async fn a_webhook_embed_with_null_fields_is_delivered() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-null-fields",
        json!({ "title": "Episode Grabbed", "fields": null }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(messages[0]["embeds"][0]["title"], "Episode Grabbed");
}

/// Control: the integer-millisecond form the route already takes.
#[tokio::test]
async fn a_webhook_embed_with_an_integer_timestamp_is_delivered() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-int-ts",
        json!({ "title": "Episode Grabbed", "timestamp": OCT_4_NOON_UTC_MS }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(messages[0]["embeds"][0]["timestamp"], OCT_4_NOON_UTC_MS);
}

#[tokio::test]
async fn a_webhook_embed_timestamp_keeps_its_offset_and_milliseconds() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-ts-exact",
        json!({ "title": "Episode Grabbed", "timestamp": "2026-10-04T14:00:00.250+02:00" }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        messages[0]["embeds"][0]["timestamp"],
        OCT_4_NOON_UTC_MS + 250
    );
}

#[tokio::test]
async fn a_dotnet_style_seven_digit_fraction_is_delivered() {
    let (status, messages) = deliver_one_embed(
        "slimm-webhook-embeds-ts-dotnet",
        json!({ "title": "Episode Grabbed", "timestamp": "2026-10-04T12:00:00.1234567Z" }),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        messages[0]["embeds"][0]["timestamp"],
        OCT_4_NOON_UTC_MS + 123
    );
}

#[tokio::test]
async fn a_bad_timestamp_drops_only_the_timestamp_and_other_embeds_still_post() {
    let (store, _guard) = new_store("slimm-webhook-embeds-bad-ts-others").await;
    let (viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "sonarr", admin_id)
        .await
        .unwrap();
    let app = app(store, LinkPreviews::disabled());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let mut first = one_embed();
    first["timestamp"] = json!("yesterday-ish");
    let mut second = one_embed();
    second["title"] = json!("Second");
    second["timestamp"] = json!(OCT_4_NOON_UTC_MS);
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "two embeds", "embeds": [first, second] }),
        ))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);

    let listed = app
        .clone()
        .oneshot(bearer_get(
            &format!("/channels/{channel_id}/messages"),
            &viewer_token,
        ))
        .await
        .unwrap();
    let messages = json_body(listed).await;
    assert_eq!(messages[0]["content"], "two embeds");
    let embeds = messages[0]["embeds"].as_array().unwrap();
    assert_eq!(embeds.len(), 2);
    assert_eq!(embeds[0]["title"], "Disk alert");
    assert_eq!(embeds[0]["description"], "root is 95% full");
    assert_eq!(embeds[0]["fields"][0]["name"], "Host");
    assert!(embeds[0]["timestamp"].is_null());
    assert_eq!(embeds[1]["title"], "Second");
    assert_eq!(embeds[1]["timestamp"], OCT_4_NOON_UTC_MS);
}

#[tokio::test]
async fn a_webhook_with_null_embeds_still_posts_its_content() {
    let (store, _guard) = new_store("slimm-webhook-embeds-null-embeds").await;
    let (viewer_token, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "sonarr", admin_id)
        .await
        .unwrap();
    let app = app(store, LinkPreviews::disabled());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let posted = app
        .clone()
        .oneshot(post_json(
            &path,
            json!({ "content": "just text", "embeds": null }),
        ))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);

    let listed = app
        .clone()
        .oneshot(bearer_get(
            &format!("/channels/{channel_id}/messages"),
            &viewer_token,
        ))
        .await
        .unwrap();
    assert_eq!(json_body(listed).await[0]["content"], "just text");
}

/// The tolerance is the webhook route's alone; this repo's own clients stay strict.
#[tokio::test]
async fn the_native_send_route_still_rejects_an_iso_timestamp() {
    let (store, _guard) = new_store("slimm-webhook-embeds-native-strict").await;
    let (token, channel_id, _admin_id) = fixture(&store, "root").await;
    let app = app(store, LinkPreviews::disabled());

    let send = |timestamp: Value| {
        Request::builder()
            .method("POST")
            .uri(format!("/channels/{channel_id}/messages"))
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(
                json!({
                    "id": "01a10e08-64f9-7b93-9098-4e507fe87e3f",
                    "content": "x",
                    "embeds": [{ "title": "t", "timestamp": timestamp }],
                })
                .to_string(),
            ))
            .unwrap()
    };
    let iso = app
        .clone()
        .oneshot(send(json!("2026-10-04T12:00:00.000Z")))
        .await
        .unwrap();
    assert_eq!(iso.status(), StatusCode::BAD_REQUEST);
    let body = json_body(iso).await;
    assert!(
        body["error"].as_str().unwrap().contains("timestamp"),
        "{body}"
    );

    let integer = app
        .clone()
        .oneshot(send(json!(OCT_4_NOON_UTC_MS)))
        .await
        .unwrap();
    assert_ne!(
        integer.status(),
        StatusCode::BAD_REQUEST,
        "the same body with an integer must get past the type check"
    );
}
