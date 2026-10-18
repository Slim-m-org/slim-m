// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /bots` versus a bot removed from the Space.
//!
//! Split out of `bots.rs` when that file crossed its budget: this is the one
//! seam the listing's default filter needs, and everything else about a bot
//! is already covered there. See `docs/decisions/0028-bot-accounts.md` for
//! why a revoked bot that is still a member stays listed while one also
//! removed from the Space does not.

use axum::Router;
use axum::http::StatusCode;
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

/// An administrator with a session, and the deployment claimed by them.
async fn admin(store: &Store, username: &str) -> (UserId, String) {
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
    (account.id, token)
}

/// Creates a bot through HTTP and hands back its id and token.
async fn create_bot(app: &Router, token: &str, username: &str) -> (String, String) {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            token,
            Some(json!({ "username": username })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let body = json_body(response).await;
    (
        body["bot"]["user_id"].as_str().unwrap().to_owned(),
        body["token"].as_str().unwrap().to_owned(),
    )
}

#[tokio::test]
async fn a_bot_removed_from_the_space_is_left_out_of_the_default_list() {
    let (store, _guard) = new_store("slimm-bots-removed-default").await;
    let (admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _bot_token) = create_bot(&app, &root, "probe").await;
    let (kept_id, _kept_token) = create_bot(&app, &root, "helper").await;
    let bot = UserId(bot_id.parse().unwrap());

    app.clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();
    store
        .remove_from_space(bot, admin_id, Some("throwaway probe"))
        .await
        .expect("removing the bot from the Space");

    let default_listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;
    let default_bots = default_listing.as_array().unwrap();
    assert_eq!(
        default_bots.len(),
        1,
        "a revoked, removed bot is noise once it is already gone from GET /members"
    );
    assert_eq!(default_bots[0]["user_id"], kept_id);

    let full_listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots?include_removed=true", &root, None))
            .await
            .unwrap(),
    )
    .await;
    let full_bots = full_listing.as_array().unwrap();
    assert_eq!(
        full_bots.len(),
        2,
        "include_removed still answers what every bot ever minted did"
    );
    assert!(
        full_bots.iter().any(|b| b["user_id"] == bot_id),
        "the removed bot's account, and its authorship, still exist"
    );
}

#[tokio::test]
async fn a_revoked_bot_still_in_the_space_is_never_hidden() {
    let (store, _guard) = new_store("slimm-bots-revoked-member").await;
    let (_admin_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (bot_id, _bot_token) = create_bot(&app, &root, "helper").await;
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/bots/{bot_id}/revoke"),
            &root,
            None,
        ))
        .await
        .unwrap();

    let listing = json_body(
        app.clone()
            .oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;
    let bots = listing.as_array().unwrap();
    assert_eq!(
        bots.len(),
        1,
        "revoked but still a member: it stays on the roster everywhere else"
    );
    assert_eq!(bots[0]["user_id"], bot_id);
}
