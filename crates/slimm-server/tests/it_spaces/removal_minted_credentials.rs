// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing a member also revokes the bot tokens and webhook URLs they hold,
//! while the bots and webhooks themselves stay for an administrator to re-key.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::{app, register_account, request_authed};

async fn status_of_me(router: &Router, token: &str) -> StatusCode {
    router
        .clone()
        .oneshot(request_authed("GET", "/me", token, None))
        .await
        .unwrap()
        .status()
}

async fn deliver(router: &Router, webhook_id: impl std::fmt::Display, token: &str) -> StatusCode {
    router
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/webhooks/{webhook_id}/{token}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "content": "ping" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap()
        .status()
}

/// The owner, a manager who will be removed, and a channel for webhooks.
async fn fixture(
    prefix: &str,
) -> (
    Store,
    Router,
    UserId,
    UserId,
    ChannelId,
    support::TestDbGuard,
) {
    let (store, guard) = support::new_store(prefix).await;
    let owner = register_account(&store, "owner").await.id;
    let manager = register_account(&store, "manager").await.id;
    let channel = store.create_channel("alerts", "text").await.unwrap().id;
    let router = app(store.clone());
    (store, router, owner, manager, channel, guard)
}

#[tokio::test]
async fn removing_a_member_revokes_the_bot_tokens_and_webhooks_they_minted() {
    let (store, router, owner, manager, channel, _guard) =
        fixture("slimm-removal-minted-revoked").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, manager)
        .await
        .unwrap();
    let hook = store
        .create_webhook(channel, "Alerts", manager)
        .await
        .unwrap();
    assert_eq!(status_of_me(&router, &bot.token).await, StatusCode::OK);
    assert!(
        deliver(&router, hook.webhook.id, &hook.token)
            .await
            .is_success()
    );

    store.remove_from_space(manager, owner, None).await.unwrap();

    assert_eq!(
        status_of_me(&router, &bot.token).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        deliver(&router, hook.webhook.id, &hook.token).await,
        StatusCode::NOT_FOUND
    );

    store.restore_to_space(manager, owner).await.unwrap();
    assert_eq!(
        status_of_me(&router, &bot.token).await,
        StatusCode::UNAUTHORIZED,
        "restoring the member does not hand their old credentials back"
    );

    let reissued = store.reissue_bot_token(bot.bot.user_id, owner).await.ok();
    let reissued = reissued.expect("the bot itself stays, for an administrator to re-key");
    assert_eq!(status_of_me(&router, &reissued.token).await, StatusCode::OK);
}

#[tokio::test]
async fn credentials_someone_else_re_keyed_since_survive_the_removal() {
    let (store, router, owner, manager, channel, _guard) =
        fixture("slimm-removal-minted-rekeyed").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::NONE, manager)
        .await
        .unwrap();
    let hook = store
        .create_webhook(channel, "Alerts", manager)
        .await
        .unwrap();
    let reissued = store.reissue_bot_token(bot.bot.user_id, owner).await.ok();
    let reissued = reissued.expect("reissue");
    let (_, rotated) = store
        .rotate_webhook(hook.webhook.id, owner)
        .await
        .unwrap()
        .unwrap();

    store.remove_from_space(manager, owner, None).await.unwrap();

    assert_eq!(status_of_me(&router, &reissued.token).await, StatusCode::OK);
    assert!(
        deliver(&router, hook.webhook.id, &rotated)
            .await
            .is_success()
    );
}
