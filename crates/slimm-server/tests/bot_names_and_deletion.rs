// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a bot's name may be, and what its account deletion takes with it.
//!
//! Split from `tests/bots.rs`, which holds provisioning and token routing and
//! sits near the file budget. Both cases here are about a claim the code makes
//! in prose that nothing was checking: that a bot name obeys a person's rules,
//! and that deleting a bot's account purges its credential rather than leaving
//! the row for a join to hide.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
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
async fn admin(store: &Store, username: &str) -> String {
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

/// Bot names claimed to follow a person's rules but restated them inline, so
/// two checks registration applies were missing: the reserved `@everyone` and
/// `@here` usernames, and the bidi/zero-width blocklist that stops a display
/// name spoofing how it renders next to everybody else's.
#[tokio::test]
async fn a_bot_name_obeys_the_rules_a_persons_name_does() {
    let (store, _guard) = new_store("slimm-bots-names").await;
    let root = admin(&store, "root").await;
    let app = app(store.clone());

    for reserved in ["everyone", "here", "EVERYONE"] {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/bots",
                &root,
                Some(json!({ "username": reserved })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "{reserved:?} is reserved for the mention, whoever is asking"
        );
    }

    let spoofed = app
        .clone()
        .oneshot(request(
            "POST",
            "/bots",
            &root,
            Some(json!({ "username": "helper", "display_name": "helper\u{202E}nimda" })),
        ))
        .await
        .unwrap();
    assert_eq!(
        spoofed.status(),
        StatusCode::BAD_REQUEST,
        "a right-to-left override must not reach the member list"
    );

    let ok = app
        .oneshot(request(
            "POST",
            "/bots",
            &root,
            Some(json!({ "username": "helper", "display_name": "Helper" })),
        ))
        .await
        .unwrap();
    assert_eq!(
        ok.status(),
        StatusCode::CREATED,
        "an ordinary name still works"
    );
}

/// Deleting a bot's account purges its token row. The generic tombstone and
/// session-revoke path already covered a person, and `authenticate_bot` joins
/// `users.deleted_at`, so a regression here needs two guards to fail at once -
/// which is exactly why nothing would have failed loudly.
#[tokio::test]
async fn deleting_a_bots_account_takes_its_token_with_it() {
    let (store, _guard) = new_store("slimm-bots-delete").await;
    let root = admin(&store, "root").await;
    let app = app(store.clone());

    let (bot_id, bot_token) = create_bot(&app, &root, "helper").await;
    let authenticates = app
        .clone()
        .oneshot(request("GET", "/me", &bot_token, None))
        .await
        .unwrap();
    assert_eq!(authenticates.status(), StatusCode::OK);

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{bot_id}/account"),
            &root,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let after = app
        .clone()
        .oneshot(request("GET", "/me", &bot_token, None))
        .await
        .unwrap();
    assert_eq!(
        after.status(),
        StatusCode::UNAUTHORIZED,
        "the deleted bot's token must stop authenticating"
    );

    // Not just masked by the deleted_at join: the credential row itself is gone.
    assert!(
        store.authenticate_bot(&bot_token).await.unwrap().is_none(),
        "the bot_tokens row must be purged, not left for the join to hide"
    );

    let listed = json_body(
        app.oneshot(request("GET", "/bots", &root, None))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        !listed
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["user_id"] == bot_id),
        "and it is gone from the bot list"
    );
}
