// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for auth against a real embedded SQLite db, plus one HTTP
//! round-trip proving the wiring end to end.
//!
//! Refresh-token rotation, its concurrent races, and reuse-triggered family
//! revocation are a separate concern with enough of their own tests to move
//! the whole file past its 500-line hard budget; they live in
//! `auth_refresh.rs`.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::{PushRegistration, RefreshOutcome, RegisterError, Store};
use tower::ServiceExt;

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-auth-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

const PASSWORD: &str = "correct horse battery staple";

/// Registers `alice` with a real Argon2id hash and returns the store, the auth
/// service, the new user id, and the store's db-cleanup guard.
async fn with_alice() -> (Store, Auth, slimm_server::ids::UserId, support::TestDbGuard) {
    let (store, guard) = store().await;
    let auth = Auth::new(2).expect("auth service");
    let hash = auth
        .hash_password(PASSWORD.to_owned())
        .await
        .expect("hash password");
    let account = store
        .create_account("alice", "Alice", &hash)
        .await
        .expect("register alice");
    (store, auth, account.id, guard)
}

#[tokio::test]
async fn access_token_resolves_to_its_session() {
    let (store, _auth, user_id, _guard) = with_alice().await;
    let tokens = store.open_session(user_id, "laptop").await.unwrap();

    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .expect("a fresh access token resolves");
    assert_eq!(ctx.user_id, user_id);
    assert_eq!(ctx.session_id, tokens.session_id);
    assert_eq!(ctx.device_id, tokens.device_id);

    // A garbage token resolves to nothing.
    assert!(
        store
            .authenticate("not-a-real-token")
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn password_verification_and_username_uniqueness() {
    let (store, auth, user_id, _guard) = with_alice().await;

    let (found_id, hash) = store
        .find_credentials("alice")
        .await
        .unwrap()
        .expect("alice exists");
    assert_eq!(found_id, user_id);
    assert!(
        auth.verify_password(PASSWORD.to_owned(), hash.clone())
            .await
            .unwrap()
    );
    assert!(
        !auth
            .verify_password("wrong".to_owned(), hash)
            .await
            .unwrap()
    );

    // Unknown user: no credentials.
    assert!(store.find_credentials("nobody").await.unwrap().is_none());

    // The live username is taken.
    let dup = store.create_account("alice", "Alice Two", "x").await;
    assert!(matches!(dup, Err(RegisterError::UsernameTaken)));
}

#[tokio::test]
async fn revoke_session_is_instant() {
    let (store, _auth, user_id, _guard) = with_alice().await;
    let tokens = store.open_session(user_id, "phone").await.unwrap();
    assert!(
        store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .is_some()
    );

    store.revoke_session(tokens.session_id).await.unwrap();

    // The bearer token stops resolving immediately, and refresh is denied.
    assert!(
        store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        store.rotate_refresh(&tokens.refresh_token).await.unwrap(),
        RefreshOutcome::Denied
    ));
}

/// The real device-revocation path is `Store::remove_device` (the dead
/// `Store::revoke_device` this used to drive was never called in production).
/// It kills the device's sessions the same way, and also clears its push
/// registration, which the dead version did not and nothing else asserts.
#[tokio::test]
async fn removing_a_device_kills_its_session_and_push_registration() {
    let (store, _auth, user_id, _guard) = with_alice().await;
    let tokens = store.open_session(user_id, "desktop").await.unwrap();
    store
        .register_push(
            user_id,
            tokens.device_id,
            PushRegistration {
                platform: "ios",
                push_token: "a-push-token",
                voip_push_token: None,
                push_public_key: &[7u8; 32],
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
    assert_eq!(
        store.push_targets(&[user_id]).await.unwrap().len(),
        1,
        "the device is a push target once registered"
    );

    store
        .remove_device(user_id, tokens.device_id)
        .await
        .unwrap()
        .expect("alice owns this device");

    assert!(
        store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        store.push_targets(&[user_id]).await.unwrap().is_empty(),
        "the removed device's push registration is gone, not just its session"
    );
}

#[tokio::test]
async fn ws_ticket_is_single_use_and_session_bound() {
    let (store, _auth, user_id, _guard) = with_alice().await;
    let tokens = store.open_session(user_id, "tablet").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();

    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    let redeemed = store
        .redeem_ws_ticket(&ticket)
        .await
        .unwrap()
        .expect("first redemption resolves the session");
    assert_eq!(redeemed, ctx);

    // Single-use: a second redemption fails, as does an unknown ticket.
    assert!(store.redeem_ws_ticket(&ticket).await.unwrap().is_none());
    assert!(
        store
            .redeem_ws_ticket("bogus-ticket")
            .await
            .unwrap()
            .is_none()
    );

    // A ticket dies with its session.
    let (ticket, _) = store.mint_ws_ticket(&ctx).await.unwrap();
    store.revoke_session(ctx.session_id).await.unwrap();
    assert!(store.redeem_ws_ticket(&ticket).await.unwrap().is_none());
}

/// End to end over HTTP: register, mint a connect ticket with the bearer token,
/// log out, and confirm the same token is then rejected.
#[tokio::test]
async fn http_register_ticket_and_logout() {
    let (store, _guard) = store().await;
    let auth = Auth::new(2).expect("auth service");
    let app = support::app::builder(store).auth(auth).router();

    // Register.
    let body = serde_json::json!({
        "username": "bob",
        "display_name": "Bob",
        "password": "hunter2hunter2",
        "device_name": "cli"
    })
    .to_string();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let access = json["access_token"].as_str().unwrap().to_owned();

    // A connect ticket requires the bearer token and succeeds.
    let ticket = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/ws-ticket")
                .header("authorization", format!("Bearer {access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(ticket.status(), StatusCode::OK);

    // Log out.
    let logout = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/logout")
                .header("authorization", format!("Bearer {access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(logout.status(), StatusCode::NO_CONTENT);

    // The same token is now rejected.
    let after = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/ws-ticket")
                .header("authorization", format!("Bearer {access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(after.status(), StatusCode::UNAUTHORIZED);
}

/// Wrong password and unknown user are both a plain 401.
#[tokio::test]
async fn http_login_rejects_bad_credentials() {
    let (store, auth, _user_id, _guard) = with_alice().await;
    let app = support::app::builder(store).auth(auth).router();

    let wrong_password = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "username": "alice",
                        "password": "the wrong password",
                        "device_name": "cli"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(wrong_password.status(), StatusCode::UNAUTHORIZED);

    let unknown_user = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "username": "ghost",
                        "password": "does not matter",
                        "device_name": "cli"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unknown_user.status(), StatusCode::UNAUTHORIZED);
}

/// A display name carrying a bidi-override character is rejected at registration.
#[tokio::test]
async fn http_register_rejects_spoofing_display_name() {
    let (store, _guard) = store().await;
    let auth = Auth::new(2).expect("auth service");
    let app = support::app::builder(store).auth(auth).router();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "username": "mallory",
                        "display_name": "\u{202E}nimda",
                        "password": "hunter2hunter2",
                        "device_name": "cli"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A connect ticket is single use. The redemption is a claim-first conditional
/// UPDATE for exactly this reason, but every other test here spends one
/// sequentially, which cannot tell an atomic claim from a check-then-write that
/// happens to work when nothing races it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_redemptions_of_one_ticket_admit_exactly_one() {
    let (store, _auth, user_id, _guard) = with_alice().await;
    let tokens = store.open_session(user_id, "laptop").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .expect("the fresh access token authenticates");
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();

    let racers = (0..8).map(|_| {
        let store = store.clone();
        let ticket = ticket.clone();
        tokio::spawn(async move { store.redeem_ws_ticket(&ticket).await })
    });
    let outcomes = futures_util::future::join_all(racers).await;

    let mut admitted = 0;
    for outcome in outcomes {
        let redeemed = outcome
            .expect("redemption task panicked")
            .expect("a racing redemption must not error");
        if redeemed.is_some() {
            admitted += 1;
        }
    }
    assert_eq!(
        admitted, 1,
        "exactly one racer may spend a single-use ticket, however many present it at once"
    );
}
