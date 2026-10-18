// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Incoming webhooks: mint, deliver, revoke, and the uniform-404 shape that
//! keeps the delivery route from being an existence oracle.
//!
//! See `docs/decisions/0030-incoming-webhooks.md`. Attribution (a webhook
//! post is reportable and moderator-deletable with no new code) is covered
//! here directly, because that is the entire point of the user-shaped
//! principal. The structural claim that a webhook credential can never
//! produce a `SessionContext` is its own file,
//! `tests/webhook_never_authenticates.rs`, in the shape
//! `tests/rate_limit_coverage.rs` already uses for a comparable claim.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body_or_null as json_body};

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

fn post_json(uri: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn bearer(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// A live administrator, the deployment they claimed, and a channel to point
/// webhooks at.
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

#[tokio::test]
async fn a_webhook_can_be_minted_used_to_post_and_revoked() {
    let (store, _guard) = new_store("slimm-webhooks-lifecycle").await;
    let (_root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store.clone());

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let posted = app
        .clone()
        .oneshot(post_json(&path, json!({ "content": "it is on fire" })))
        .await
        .unwrap();
    assert_eq!(posted.status(), StatusCode::NO_CONTENT);

    assert!(
        store
            .revoke_webhook(minted.webhook.id, admin_id)
            .await
            .unwrap(),
        "revoking a webhook that exists reports it existed"
    );

    let posted_again = app
        .clone()
        .oneshot(post_json(&path, json!({ "content": "still on fire" })))
        .await
        .unwrap();
    assert_eq!(
        posted_again.status(),
        StatusCode::NOT_FOUND,
        "revocation is immediate, not eventual"
    );
}

#[tokio::test]
async fn wait_true_answers_the_minimal_acknowledgement() {
    let (store, _guard) = new_store("slimm-webhooks-wait").await;
    let (_root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store);

    let path = format!("/webhooks/{}/{}?wait=true", minted.webhook.id, minted.token);
    let response = app
        .oneshot(post_json(&path, json!({ "content": "hello" })))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["channel_id"], channel_id.to_string());
    assert!(body["id"].is_string());
    assert!(body["seq"].is_i64());
    assert!(body["created_at"].is_i64());
}

#[tokio::test]
async fn missing_wrong_and_revoked_all_answer_the_identical_404() {
    let (store, _guard) = new_store("slimm-webhooks-uniform-404").await;
    let (_root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store.clone());

    let never_existed = format!("/webhooks/{}/{}", uuid::Uuid::now_v7(), "not-a-real-token");
    let wrong_token = format!("/webhooks/{}/wrong-token", minted.webhook.id);

    store
        .revoke_webhook(minted.webhook.id, admin_id)
        .await
        .unwrap();
    let revoked = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);

    for path in [
        never_existed.as_str(),
        wrong_token.as_str(),
        revoked.as_str(),
    ] {
        let response = app
            .clone()
            .oneshot(post_json(path, json!({ "content": "hi" })))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "{path} did not answer 404"
        );
    }
}

#[tokio::test]
async fn an_unknown_payload_field_is_accepted_and_discarded() {
    let (store, _guard) = new_store("slimm-webhooks-accept-discard").await;
    let (_root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store);

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let response = app
        .oneshot(post_json(
            &path,
            json!({
                "content": "a grafana panel fired",
                "embeds": [{"title": "cpu spike"}],
                "avatar_url": "https://example.invalid/pic.png",
                "tts": true,
                "some_field_nobody_has_ever_named": {"nested": [1, 2, 3]},
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::NO_CONTENT,
        "an unrecognised field must never turn a working delivery into a 400"
    );
}

#[tokio::test]
async fn a_repeated_idempotency_key_lands_on_the_same_message() {
    let (store, _guard) = new_store("slimm-webhooks-idempotency").await;
    let (_root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store.clone());

    let path = format!("/webhooks/{}/{}?wait=true", minted.webhook.id, minted.token);
    let request = |body: Value| {
        Request::builder()
            .method("POST")
            .uri(&path)
            .header("content-type", "application/json")
            .header("idempotency-key", "sonarr-episode-42")
            .body(Body::from(body.to_string()))
            .unwrap()
    };

    let first = json_body(
        app.clone()
            .oneshot(request(json!({ "content": "episode 42 downloaded" })))
            .await
            .unwrap(),
    )
    .await;
    let second = json_body(
        app.oneshot(request(json!({ "content": "episode 42 downloaded" })))
            .await
            .unwrap(),
    )
    .await;

    assert_eq!(
        first["id"], second["id"],
        "the same Idempotency-Key must resolve to the same message id"
    );

    let history = store.list_messages(channel_id, None, 10).await.unwrap();
    assert_eq!(
        history.len(),
        1,
        "a retried delivery with the same key must not double-post"
    );
}

/// A plain member reports the webhook's message through the same route
/// anyone uses to report a person's - no webhook-specific handling anywhere
/// in that path - and a moderator deletes it through the same
/// MANAGE_MESSAGES split every message's authorship already has: not the
/// author, since nobody ever signs in as a webhook, so this only succeeds
/// because root holds MANAGE_MESSAGES deployment-wide.
#[tokio::test]
async fn a_webhook_post_is_reportable_and_moderator_deletable_with_no_new_code() {
    let (store, _guard) = new_store("slimm-webhooks-attribution").await;
    let (root, channel_id, admin_id) = fixture(&store, "root").await;
    let minted = store
        .create_webhook(channel_id, "alerts", admin_id)
        .await
        .unwrap();
    let app = app(store.clone());

    let path = format!("/webhooks/{}/{}?wait=true", minted.webhook.id, minted.token);
    let delivered = json_body(
        app.clone()
            .oneshot(post_json(&path, json!({ "content": "disk is full" })))
            .await
            .unwrap(),
    )
    .await;
    let message_id = delivered["id"].as_str().unwrap().to_owned();

    let bob = store.create_user("bob", "Bob").await.unwrap();
    let bob_token = store
        .open_session(bob.id, "phone")
        .await
        .unwrap()
        .access_token;
    let reported = app
        .clone()
        .oneshot(post_json_with_auth(
            "/reports",
            &bob_token,
            json!({
                "subject_kind": "message",
                "subject_id": message_id,
                "reason": "spam",
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        reported.status(),
        StatusCode::OK,
        "reporting a webhook's message"
    );

    let open_reports = store.list_open_reports(None, &[], 10).await.unwrap();
    let report = open_reports
        .iter()
        .find(|r| r.subject_id.to_string() == message_id)
        .expect("the report was filed");
    assert_eq!(
        report.subject_author_id,
        Some(minted.webhook.principal_id),
        "the report names the webhook's own principal as the message's author"
    );

    let deleted = app
        .oneshot(bearer(
            "DELETE",
            &format!("/channels/{channel_id}/messages/{message_id}"),
            &root,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
}

fn post_json_with_auth(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}
