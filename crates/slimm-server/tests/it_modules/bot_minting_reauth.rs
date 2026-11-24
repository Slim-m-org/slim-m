// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot token that carries ADMINISTRATOR is worth the password behind it, so
//! minting, re-keying or raising one asks for that password; other bots do not.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
use support::app::{app, call_as};

const PASSWORD: &str = "correct-horse-battery";

/// The deployment's owner, signed in with a real password.
async fn owner(prefix: &str) -> (Store, Router, String, support::TestDbGuard) {
    let (store, guard) = support::new_store(prefix).await;
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let account = store.create_account("root", "root", &hash).await.unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let router = app(store.clone());
    (store, router, token, guard)
}

fn admin_bits() -> i64 {
    Permissions::ADMINISTRATOR.bits()
}

async fn create(router: &Router, token: &str, body: Value) -> (StatusCode, Value) {
    call_as(router, "POST", "/bots", token, Some(body)).await
}

#[tokio::test]
async fn minting_an_administrator_bot_needs_the_password() {
    let (_store, router, root, _guard) = owner("slimm-bot-reauth-create").await;

    let (status, _) = create(
        &router,
        &root,
        json!({ "username": "warden", "permissions": admin_bits() }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = create(
        &router,
        &root,
        json!({ "username": "warden", "permissions": admin_bits(), "password": "wrong-password" }),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, body) = create(
        &router,
        &root,
        json!({ "username": "warden", "permissions": admin_bits(), "password": PASSWORD }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn an_ordinary_bot_needs_no_password() {
    let (_store, router, root, _guard) = owner("slimm-bot-reauth-ordinary").await;
    let send = Permissions::SEND_MESSAGES.bits();
    let (status, body) = create(
        &router,
        &root,
        json!({ "username": "helper", "permissions": send }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}

#[tokio::test]
async fn re_keying_an_administrator_bot_needs_the_password() {
    let (_store, router, root, _guard) = owner("slimm-bot-reauth-reissue").await;
    let (_, body) = create(
        &router,
        &root,
        json!({ "username": "warden", "permissions": admin_bits(), "password": PASSWORD }),
    )
    .await;
    let bot_id = body["bot"]["user_id"].as_str().unwrap().to_owned();
    let uri = format!("/bots/{bot_id}/token");

    let (status, _) = call_as(&router, "POST", &uri, &root, None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, body) = call_as(
        &router,
        "POST",
        &uri,
        &root,
        Some(json!({ "password": PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn re_keying_an_ordinary_bot_needs_no_password() {
    let (_store, router, root, _guard) = owner("slimm-bot-reauth-reissue-ordinary").await;
    let (_, body) = create(&router, &root, json!({ "username": "helper" })).await;
    let bot_id = body["bot"]["user_id"].as_str().unwrap().to_owned();
    let (status, body) = call_as(
        &router,
        "POST",
        &format!("/bots/{bot_id}/token"),
        &root,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn raising_a_bot_to_administrator_needs_the_password() {
    let (_store, router, root, _guard) = owner("slimm-bot-reauth-raise").await;
    let (_, body) = create(&router, &root, json!({ "username": "helper" })).await;
    let bot_id = body["bot"]["user_id"].as_str().unwrap().to_owned();
    let uri = format!("/bots/{bot_id}/permissions");

    let (status, _) = call_as(
        &router,
        "PATCH",
        &uri,
        &root,
        Some(json!({ "permissions": admin_bits() })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, body) = call_as(
        &router,
        "PATCH",
        &uri,
        &root,
        Some(json!({ "permissions": admin_bits(), "password": PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}
