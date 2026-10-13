// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /channels/{id}/messages` accepting `embeds` - the bot half.

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
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

struct Harness {
    app: Router,
    store: Store,
    channel_id: String,
    _guard: support::TestDbGuard,
}

async fn harness(link_previews: LinkPreviews) -> Harness {
    let (path, guard) = support::TestDbGuard::new("slimm-message-embeds-send-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_SERVER),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = http::router(AppState {
        store: store.clone(),
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
    });
    Harness {
        app,
        store,
        channel_id: channel.id.to_string(),
        _guard: guard,
    }
}

fn request(method: &str, uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(method)
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
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// A member with a session.
async fn member(store: &Store, username: &str) -> String {
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

/// A bot, minted by an administrator through the real route.
async fn bot(app: &Router, admin_token: &str, username: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            admin_token,
            json!({ "username": username }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await["token"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn send_with_embeds(channel_id: &str, token: &str, embeds: Value) -> Request<Body> {
    request(
        "POST",
        &format!("/channels/{channel_id}/messages"),
        token,
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "a build result",
            "embeds": embeds,
        }),
    )
}

fn one_embed(overrides: Value) -> Value {
    let mut base = json!({
        "title": "Build failed",
        "description": "main is red",
        "color": 0xE0_3B3B_i64,
        "fields": [{ "name": "Job", "value": "server-ci", "inline": true }],
    });
    if let (Value::Object(base_map), Value::Object(over_map)) = (&mut base, overrides) {
        base_map.extend(over_map);
    }
    base
}

#[tokio::test]
async fn a_bot_can_post_an_embed_and_it_renders() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(json!({}))]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    let embeds = body["embeds"].as_array().unwrap();
    assert_eq!(embeds.len(), 1);
    assert_eq!(embeds[0]["title"], "Build failed");
    assert_eq!(embeds[0]["accent"], "red");
    assert_eq!(embeds[0]["fields"][0]["name"], "Job");
}

/// A person's composer has no embed UI; the route enforces that too.
#[tokio::test]
async fn a_non_bots_embeds_are_silently_discarded_not_refused() {
    let h = harness(LinkPreviews::disabled()).await;
    let alice_token = member(&h.store, "alice").await;

    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &alice_token,
            json!([one_embed(json!({}))]),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "a person's embeds are dropped, never refused"
    );
    let body = json_body(response).await;
    assert_eq!(body["embeds"], json!([]));
}

#[tokio::test]
async fn too_many_embeds_is_a_400() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let eleven: Vec<Value> = (0..11).map(|_| one_embed(json!({}))).collect();
    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(&h.channel_id, &bot_token, json!(eleven)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_over_long_title_is_a_400_naming_how_far_over() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let long_title = "x".repeat(300);
    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(json!({ "title": long_title }))]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = json_body(response).await;
    let message = body["error"].as_str().unwrap_or_default();
    assert!(
        message.contains("44") && message.contains("256"),
        "expected the overrun and the limit named, got: {message}"
    );
}

#[tokio::test]
async fn too_many_fields_is_a_400() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let fields: Vec<Value> = (0..26)
        .map(|i| json!({ "name": format!("f{i}"), "value": "v" }))
        .collect();
    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(json!({ "fields": fields }))]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn an_empty_field_name_is_a_400() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(
                json!({ "fields": [{ "name": "  ", "value": "v" }] })
            )]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Decision 0030's motivating case: an internal snapshot must not block the rest.
#[tokio::test]
async fn a_bots_embed_image_pointed_at_a_blocked_address_is_dropped() {
    let h = harness(LinkPreviews::new(
        &Config {
            link_previews: true,
            ..Config::default()
        },
        [7; 32],
    ))
    .await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(json!({
                "image": { "url": "http://169.254.169.254/panel.png" },
            }))]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert!(body["embeds"][0]["image_token"].is_null());
    assert_eq!(body["embeds"][0]["title"], "Build failed");
}

/// An edit carries no `embeds` field; the stored embed must survive it.
#[tokio::test]
async fn editing_a_message_does_not_delete_its_stored_embed() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let sent = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(json!({}))]),
        ))
        .await
        .unwrap();
    let sent_body = json_body(sent).await;
    let message_id = sent_body["id"].as_str().unwrap();

    let edited = h
        .app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{}/messages/{message_id}", h.channel_id),
            &bot_token,
            json!({ "content": "build failed, retrying" }),
        ))
        .await
        .unwrap();
    assert_eq!(edited.status(), StatusCode::OK);
    assert_eq!(json_body(edited).await["content"], "build failed, retrying");

    let listed = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/channels/{}/messages", h.channel_id))
                .header("authorization", format!("Bearer {bot_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let messages = json_body(listed).await;
    let message = messages
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == message_id)
        .expect("the edited message is still in the channel");
    let embeds = message["embeds"].as_array().unwrap();
    assert_eq!(
        embeds.len(),
        1,
        "an edit must not delete the embed it was sent with"
    );
    assert_eq!(embeds[0]["title"], "Build failed");
    assert_eq!(
        message["content"], "build failed, retrying",
        "the edit itself did take effect"
    );
}

#[tokio::test]
async fn an_embed_link_must_be_a_plain_web_link() {
    let h = harness(LinkPreviews::disabled()).await;
    let admin_token = member(&h.store, "admin").await;
    let bot_token = bot(&h.app, &admin_token, "ci-bot").await;

    let bad = [
        json!({"url": "javascript:alert(1)"}),
        json!({"url": "file:///etc/passwd"}),
        json!({"url": format!("https://example.com/{}", "a".repeat(600))}),
        json!({"author": {"name": "ci", "url": "javascript:alert(1)"}}),
        json!({"author": {"name": "ci", "url": "https://user:pw@example.com"}}),
    ];
    for overrides in bad {
        let response = h
            .app
            .clone()
            .oneshot(send_with_embeds(
                &h.channel_id,
                &bot_token,
                json!([one_embed(overrides.clone())]),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{overrides}");
    }

    let good = json!({"url": "https://ci.example/run/1", "author": {"name": "ci", "url": "https://ci.example"}});
    let response = h
        .app
        .clone()
        .oneshot(send_with_embeds(
            &h.channel_id,
            &bot_token,
            json!([one_embed(good)]),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}
