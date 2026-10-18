// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The harness the two TOTP test binaries share: a real router over a real
//! migrated database, a signed-in member, and enrolment driven through the
//! actual routes rather than the store.
//!
//! Its own module rather than a copy in each file, because enrolling means four
//! sequential requests and a duplicated version of that is exactly where the
//! two suites would quietly stop testing the same thing.
#![allow(dead_code)]

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::store::Store;
use tower::ServiceExt;

/// The password every account in these tests is created with, hashed for real
/// so `/auth/login` exercises the same Argon2id path production does.
pub const PASSWORD: &str = "correct-horse-battery";

pub async fn new_store(prefix: &str) -> (Store, Auth, crate::support::TestDbGuard) {
    let (path, guard) = crate::support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), Auth::new(2).unwrap(), guard)
}

pub fn app(store: Store, auth: Auth) -> Router {
    app_with_hub(store, auth, Hub::new())
}

pub fn app_with_hub(store: Store, auth: Auth, hub: Hub) -> Router {
    crate::support::app::builder(store)
        .auth(auth)
        .hub(hub)
        .router()
}

pub fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

pub async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a real password hash and a live session.
///
/// Built through the store rather than `/auth/register`, the way
/// `tests/recovery.rs` does and for the same reason: joining a claimed
/// deployment is an invite-gated policy decision with its own tests, and these
/// suites only need somebody signed in.
pub async fn member(store: &Store, auth: &Auth, username: &str) -> (String, String) {
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

/// Drives `/auth/totp/enrol` and returns the secret, without confirming.
pub async fn begin_enrolment(app: &Router, token: &str) -> String {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/totp/enrol",
            Some(token),
            Some(json!({ "password": PASSWORD })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "enrolment should start");
    json_body(response).await["secret"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn confirm_previous_step(
    app: &Router,
    token: &str,
    secret: &str,
) -> axum::response::Response {
    let code = slimm_server::totp::code_at(secret, now_ms() - STEP_MS).unwrap();
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/totp/confirm",
            Some(token),
            Some(json!({ "code": code, "password": PASSWORD })),
        ))
        .await
        .unwrap()
}

/// Enrols and confirms, returning the secret and the recovery codes.
///
/// Confirms with the *previous* step's code, which is inside the skew window and
/// leaves the current step unspent. That is not a trick to get around the replay
/// guard, it is what a real enrolment looks like: somebody confirms and then
/// signs in later with a code they have not used. Confirming with the current
/// step would leave every caller of this unable to sign in until the clock
/// rolled over, which is correct behaviour and useless to test against.
pub async fn enrol_and_confirm(app: &Router, token: &str) -> (String, Vec<String>) {
    let secret = begin_enrolment(app, token).await;
    // The password check can take seconds on a loaded runner, long enough to step past the window, so a refused code is recomputed.
    let mut response = confirm_previous_step(app, token, &secret).await;
    for _ in 0..2 {
        if response.status() != StatusCode::BAD_REQUEST {
            break;
        }
        response = confirm_previous_step(app, token, &secret).await;
    }
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "confirmation should pass"
    );
    let codes = json_body(response).await["recovery_codes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap().to_owned())
        .collect();
    (secret, codes)
}

/// Posts a password to `/auth/login` and returns the response, so a caller can
/// assert on 200 against 202 itself.
pub async fn login(app: &Router, username: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/login",
            None,
            Some(json!({
                "username": username,
                "password": PASSWORD,
                "device_name": "phone",
            })),
        ))
        .await
        .unwrap()
}

/// Signs in as far as the challenge and returns it, asserting the 202 on the
/// way: a test that meant to exercise the second factor and silently got a
/// session instead would otherwise pass for the wrong reason.
pub async fn login_for_challenge(app: &Router, username: &str) -> String {
    let response = login(app, username).await;
    assert_eq!(
        response.status(),
        StatusCode::ACCEPTED,
        "an enabled factor must not mint a session from the password alone"
    );
    json_body(response).await["totp_challenge"]
        .as_str()
        .unwrap()
        .to_owned()
}

pub async fn verify(app: &Router, challenge: &str, code: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "POST",
            "/auth/totp/verify",
            None,
            Some(json!({ "challenge": challenge, "code": code })),
        ))
        .await
        .unwrap()
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Milliseconds in one counter step, for the tests that need a code from
/// outside the accepted window.
pub const STEP_MS: i64 = 30 * 1000;
