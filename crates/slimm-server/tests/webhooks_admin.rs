// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Minting, listing, renaming and revoking webhooks: the MANAGE_SERVER gate,
//! the one-time delivery path, and revocation taking effect immediately.
//!
//! Delivery itself, and the uniform 404 it gives an unknown or revoked
//! credential, is `tests/webhooks.rs`'s job; this file only covers the admin
//! routes `http/webhooks_admin.rs` adds on top of it.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body_or_null as json_body, request_authed as request};

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

/// An administrator with a session, the deployment claimed by them, and a
/// channel to point webhooks at.
async fn admin(store: &Store, username: &str) -> (UserId, String, String) {
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
    let channel = store.create_channel("general", "text").await.unwrap();
    (account.id, token, channel.id.to_string())
}

#[tokio::test]
async fn manage_server_can_mint_list_rename_and_revoke_a_webhook() {
    let (store, _guard) = new_store("slimm-webhooks-admin-lifecycle").await;
    let (_admin_id, root, channel_id) = admin(&store, "root").await;
    let app = app(store);

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/webhooks",
                &root,
                Some(json!({ "channel_id": channel_id, "label": "alerts" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(created["webhook"]["label"], "alerts");
    assert_eq!(created["webhook"]["channel_id"], channel_id);
    let delivery_path = created["delivery_path"].as_str().unwrap();
    assert!(
        delivery_path.starts_with("/webhooks/"),
        "the mint response must carry a pasteable delivery path exactly once"
    );
    let webhook_id = created["webhook"]["id"].as_str().unwrap().to_owned();

    let listing = json_body(
        app.clone()
            .oneshot(request("GET", "/webhooks", &root, None))
            .await
            .unwrap(),
    )
    .await;
    let entries = listing.as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert!(
        entries[0].get("delivery_path").is_none() && entries[0].get("token").is_none(),
        "a listing must never carry a webhook's credential again"
    );
    assert_eq!(entries[0]["created_by_display_name"], "root");

    let renamed = json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/webhooks/{webhook_id}"),
                &root,
                Some(json!({ "label": "renamed-alerts" })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(renamed["label"], "renamed-alerts");

    let revoked = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/webhooks/{webhook_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);

    let delivery = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(delivery_path)
                .header("content-type", "application/json")
                .body(Body::from(json!({ "content": "too late" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        delivery.status(),
        StatusCode::NOT_FOUND,
        "revocation must take effect immediately"
    );
}

#[tokio::test]
async fn an_ordinary_member_cannot_provision_list_or_revoke_webhooks() {
    let (store, _guard) = new_store("slimm-webhooks-admin-member").await;
    let (_admin_id, root, channel_id) = admin(&store, "root").await;
    let member = store.create_user("mallory", "Mallory").await.unwrap();
    let token = store
        .open_session(member.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let app = app(store.clone());

    let minted = store
        .create_webhook(
            slimm_server::ids::ChannelId(uuid::Uuid::parse_str(&channel_id).unwrap()),
            "alerts",
            _admin_id,
        )
        .await
        .unwrap();

    for (method, uri, body) in [
        (
            "POST",
            "/webhooks".to_owned(),
            Some(json!({ "channel_id": channel_id, "label": "sneaky" })),
        ),
        ("GET", "/webhooks".to_owned(), None),
        (
            "POST",
            format!("/webhooks/{}/rotate", minted.webhook.id),
            None,
        ),
        (
            "POST",
            format!("/webhooks/{}/revoke", minted.webhook.id),
            None,
        ),
    ] {
        let response = app
            .clone()
            .oneshot(request(method, &uri, &token, body))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::FORBIDDEN,
            "{method} {uri} needs MANAGE_SERVER"
        );
    }

    let _ = root; // root only exists to stand up the deployment for this fixture.
}

#[tokio::test]
async fn creating_a_webhook_on_an_unknown_channel_answers_404() {
    let (store, _guard) = new_store("slimm-webhooks-admin-unknown-channel").await;
    let (_admin_id, root, _channel_id) = admin(&store, "root").await;
    let app = app(store);

    let response = app
        .oneshot(request(
            "POST",
            "/webhooks",
            &root,
            Some(json!({
                "channel_id": uuid::Uuid::now_v7().to_string(),
                "label": "alerts",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn rotating_a_webhook_replaces_its_token_and_keeps_its_principal() {
    let (path, _guard) = support::TestDbGuard::new("slimm-webhooks-admin-rotate");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool.clone());
    let (admin_id, root, channel_id) = admin(&store, "root").await;
    let app = app(store.clone());

    let minted = store
        .create_webhook(
            slimm_server::ids::ChannelId(uuid::Uuid::parse_str(&channel_id).unwrap()),
            "alerts",
            admin_id,
        )
        .await
        .unwrap();
    let old_path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);

    let rotated = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/webhooks/{}/rotate", minted.webhook.id),
                &root,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let new_path = rotated["delivery_path"].as_str().unwrap().to_owned();
    assert_ne!(new_path, old_path, "rotation must issue a different token");
    assert_eq!(rotated["webhook"]["id"], minted.webhook.id.to_string());

    let deliver = |path: String| {
        let app = app.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "content": "ping" }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
        }
    };
    assert_eq!(
        deliver(old_path).await,
        StatusCode::NOT_FOUND,
        "the leaked URL must stop working at once"
    );
    assert!(deliver(new_path).await.is_success(), "the new URL delivers");

    let principals: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT user_id FROM webhooks")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(
        principals[0].0.as_slice(),
        minted.webhook.principal_id.0.as_bytes().as_slice(),
        "rotation must keep the principal so history stays attributed"
    );

    let actions: Vec<(String,)> =
        sqlx::query_as("SELECT action FROM moderation_audit_log WHERE subject_id = ? ORDER BY id")
            .bind(minted.webhook.principal_id)
            .fetch_all(&pool)
            .await
            .unwrap();
    let actions: Vec<&str> = actions.iter().map(|(a,)| a.as_str()).collect();
    assert_eq!(actions, vec!["webhook_create", "webhook_rotate"]);

    let unknown = app
        .oneshot(request(
            "POST",
            &format!("/webhooks/{}/rotate", uuid::Uuid::now_v7()),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
}
