// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Tests for first-run bootstrap and the channel routes, including the full
//! register-to-message flow a fresh deployment must support.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::{Bootstrap, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, request};

async fn new_store() -> (Store, support::TestDbGuard) {
    let (store, _pool, guard) = new_store_with_pool().await;
    (store, guard)
}

async fn new_store_with_pool() -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-boot-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

/// Registers the account that claims the deployment. Only valid first: a
/// claimed deployment takes an invite (see [`join`]).
async fn register(app: &Router, username: &str) -> String {
    signup(app, username, None).await
}

/// Joins an already-claimed deployment, minting an invite with `host`'s token
/// the way a real member gets in.
async fn join(app: &Router, host: &str, username: &str) -> String {
    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(host), Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let code = json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned();
    signup(app, username, Some(&code)).await
}

fn signup_request(username: &str, invite_code: Option<&str>) -> Request<Body> {
    let mut body = json!({
        "username": username,
        "display_name": username,
        "password": "hunter2hunter2",
        "device_name": "cli"
    });
    if let Some(code) = invite_code {
        body["invite_code"] = json!(code);
    }
    request("POST", "/auth/register", None, Some(body))
}

async fn signup(app: &Router, username: &str, invite_code: Option<&str>) -> String {
    let response = app
        .clone()
        .oneshot(signup_request(username, invite_code))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await["access_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn first_account_claims_the_deployment_and_can_message() {
    let (store, _guard) = new_store().await;
    assert!(!store.is_bootstrapped().await.unwrap());
    let app = app(store.clone());

    // Registering the first account seeds roles and a general channel.
    let admin = register(&app, "alice").await;
    assert!(store.is_bootstrapped().await.unwrap());

    // That account can see the seeded channel.
    let channels = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&admin), None))
            .await
            .unwrap(),
    )
    .await;
    let channels = channels.as_array().unwrap();
    assert_eq!(channels.len(), 1);
    assert_eq!(channels[0]["name"], "general");
    let categories = json_body(
        app.clone()
            .oneshot(request("GET", "/categories", Some(&admin), None))
            .await
            .unwrap(),
    )
    .await;
    let text = categories
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "Text")
        .expect("default Text category");
    assert_eq!(channels[0]["category_id"], text["id"]);
    let channel_id = channels[0]["id"].as_str().unwrap().to_owned();

    // And can send into it end to end, which is the flow a fresh deployment
    // could not do before bootstrap existed.
    let sent = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(&admin),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": "first post" })),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    assert_eq!(json_body(sent).await["seq"], 1);

    // A second account joins on an invite, inherits @everyone, and can also
    // read and send.
    let member = join(&app, &admin, "bob").await;
    let listed = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages"),
                Some(&member),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn bootstrap_runs_only_once() {
    let (store, _guard) = new_store().await;
    let first = store.create_user("alice", "Alice").await.unwrap();
    let second = store.create_user("bob", "Bob").await.unwrap();

    assert_eq!(
        store.bootstrap_deployment(first.id).await.unwrap(),
        Bootstrap::Claimed
    );
    // A second attempt changes nothing, so a later registration cannot seed a
    // competing set of roles or grant itself admin.
    assert_eq!(
        store.bootstrap_deployment(second.id).await.unwrap(),
        Bootstrap::AlreadySetUp
    );
    assert_eq!(store.list_channels().await.unwrap().len(), 1);
}

#[tokio::test]
async fn only_a_manager_can_create_channels() {
    let (store, _guard) = new_store().await;
    let app = app(store);
    let admin = register(&app, "alice").await;
    let member = join(&app, &admin, "bob").await;

    // The bootstrap admin can create one.
    let created = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&admin),
            Some(json!({ "name": "gaming" })),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    assert_eq!(json_body(created).await["name"], "gaming");

    // An ordinary member cannot.
    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&member),
            Some(json!({ "name": "sneaky" })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);

    // Validation still applies to the admin.
    let bad = app
        .clone()
        .oneshot(request(
            "POST",
            "/channels",
            Some(&admin),
            Some(json!({ "name": "  " })),
        ))
        .await
        .unwrap();
    assert_eq!(bad.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn channel_list_requires_authentication() {
    let (store, _guard) = new_store().await;
    let app = app(store);
    let response = app
        .oneshot(request("GET", "/channels", None, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// The password class refuses a caller past its burst, so a flood cannot keep
/// Enough logins to outrun the password bucket's refill on any runner.
///
/// Sized rather than tuned, the same way `resource_bounds.rs` sizes its own.
/// The bucket is ten with one back every three seconds, so a loop slow enough
/// per request never empties it: at two seconds each, thirty would still be
/// admitted. A fixed fourteen passed on a laptop and failed on CI, which is a
/// number tuned to one machine rather than a bound. The loop breaks at the
/// first refusal, so this ceiling costs nothing in the normal case.
const ENOUGH_TO_EXHAUST: usize = 40;

/// the Argon2id permits saturated.
#[tokio::test]
async fn password_endpoints_are_rate_limited() {
    let (store, _guard) = new_store().await;
    let app = app(store);

    let mut statuses = Vec::new();
    for i in 0..ENOUGH_TO_EXHAUST {
        let response = app
            .clone()
            .oneshot(request(
                "POST",
                "/auth/login",
                None,
                Some(json!({
                    "username": format!("nobody{i}"),
                    "password": "hunter2hunter2",
                    "device_name": "cli"
                })),
            ))
            .await
            .unwrap();
        let status = response.status();
        statuses.push(status);
        if status == StatusCode::TOO_MANY_REQUESTS {
            break;
        }
    }

    // Early attempts answer 401 (no such user); past the burst the limiter takes over.
    assert!(
        statuses.contains(&StatusCode::UNAUTHORIZED),
        "early attempts are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained flood is refused: {statuses:?}"
    );
}

/// Registering and claiming are one transaction: when seeding the deployment
/// fails, the first account must not be left behind as a plain member with the
/// deployment unclaimed for the next registrant to take.
#[tokio::test]
async fn a_failed_claim_does_not_hand_the_deployment_to_the_next_registrant() {
    let (store, pool, _guard) = new_store_with_pool().await;
    let app = app(store.clone());

    for statement in [
        "CREATE TABLE claim_fault (on_ INTEGER)",
        "INSERT INTO claim_fault VALUES (1)",
        "CREATE TRIGGER claim_boom BEFORE INSERT ON channels WHEN (SELECT on_ FROM claim_fault) = 1
         BEGIN SELECT RAISE(ABORT, 'injected'); END",
    ] {
        sqlx::query(statement).execute(&pool).await.unwrap();
    }

    let first = app
        .clone()
        .oneshot(signup_request("alice", None))
        .await
        .unwrap();
    assert!(first.status().is_server_error(), "{}", first.status());
    sqlx::query("UPDATE claim_fault SET on_ = 0")
        .execute(&pool)
        .await
        .unwrap();

    let retry = app
        .clone()
        .oneshot(signup_request("alice", None))
        .await
        .unwrap();
    assert_eq!(retry.status(), StatusCode::OK, "alice retries her own name");
    let bob = app
        .clone()
        .oneshot(signup_request("bob", None))
        .await
        .unwrap();
    assert_eq!(
        bob.status(),
        StatusCode::BAD_REQUEST,
        "bob now needs an invite"
    );
}
