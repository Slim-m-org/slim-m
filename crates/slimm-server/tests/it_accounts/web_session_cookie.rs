// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A browser's refresh token travels in an HttpOnly cookie, never in the body (decision 0141).
//!
//! The web client asks for it with the `x-slimm-web-session: cookie` header; every other client is untouched.

use axum::Router;
use axum::body::Body;
use axum::http::header::{COOKIE, SET_COOKIE};
use axum::http::{HeaderMap, Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;

const WEB: (&str, &str) = ("x-slimm-web-session", "cookie");
const PASSWORD: &str = "hunter2hunter2";

async fn app(prefix: &str) -> (Router, support::TestDbGuard) {
    let (app, _, guard) = app_with_store(prefix).await;
    (app, guard)
}

async fn app_with_store(prefix: &str) -> (Router, Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    let auth = Auth::new(2).expect("auth service");
    (
        support::app::builder(store.clone()).auth(auth).router(),
        store,
        guard,
    )
}

fn post(uri: &str, headers: &[(&str, &str)], body: Value) -> Request<Body> {
    let mut builder = Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json");
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    builder.body(Body::from(body.to_string())).unwrap()
}

async fn send(app: &Router, request: Request<Body>) -> (StatusCode, HeaderMap, Value) {
    let response = app.clone().oneshot(request).await.unwrap();
    let (status, headers) = (response.status(), response.headers().clone());
    (
        status,
        headers,
        support::app::json_body_or_null(response).await,
    )
}

fn register_body(name: &str) -> Value {
    json!({"username": name, "password": PASSWORD, "device_name": "browser"})
}

fn cookie_header(headers: &HeaderMap) -> String {
    let all: Vec<_> = headers.get_all(SET_COOKIE).iter().collect();
    assert_eq!(all.len(), 1, "exactly one Set-Cookie");
    all[0].to_str().unwrap().to_owned()
}

/// The `name=value` pair of a Set-Cookie line, as a browser would send it back.
fn pair(set_cookie: &str) -> String {
    set_cookie.split(';').next().unwrap().to_owned()
}

fn cookie_token(set_cookie: &str) -> String {
    pair(set_cookie).split_once('=').unwrap().1.to_owned()
}

async fn web_register(app: &Router, name: &str) -> (Value, String) {
    let (status, headers, body) =
        send(app, post("/auth/register", &[WEB], register_body(name))).await;
    assert_eq!(status, StatusCode::OK);
    (body, cookie_header(&headers))
}

fn refresh_with_cookie(user_id: &str, cookie: &str, extra: &[(&str, &str)]) -> Request<Body> {
    let mut headers = vec![("x-slimm-account", user_id)];
    headers.extend_from_slice(extra);
    let mut request = post("/auth/refresh", &headers, json!({"client_kind": "web"}));
    request
        .headers_mut()
        .insert(COOKIE, cookie.parse().unwrap());
    request
}

#[tokio::test]
async fn a_web_sign_in_sets_an_http_only_cookie_and_leaves_the_body_token_out() {
    let (app, _guard) = app("slimm-web-cookie-set").await;
    let (body, set_cookie) = web_register(&app, "webby").await;

    assert!(body.get("refresh_token").is_none(), "body: {body}");
    assert!(body["access_token"].as_str().is_some_and(|t| !t.is_empty()));
    let user_id = body["user_id"].as_str().unwrap();
    assert!(set_cookie.starts_with(&format!("__Secure-slimm_rt_{user_id}=")));
    for attribute in [
        "; HttpOnly",
        "; Secure;",
        "; SameSite=Strict",
        "; Path=/auth/refresh",
        "; Max-Age=",
    ] {
        assert!(
            set_cookie.contains(attribute),
            "{attribute} missing in {set_cookie}"
        );
    }

    let (status, headers, body) = send(
        &app,
        post(
            "/auth/login",
            &[WEB],
            json!({"username": "webby", "password": PASSWORD, "device_name": "b"}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.get("refresh_token").is_none());
    assert!(cookie_header(&headers).contains("HttpOnly"));
}

#[tokio::test]
async fn refresh_reads_the_cookie_and_rotates_it() {
    let (app, _guard) = app("slimm-web-cookie-rotate").await;
    let (body, set_cookie) = web_register(&app, "rotator").await;
    let user_id = body["user_id"].as_str().unwrap();

    let (status, headers, refreshed) = send(
        &app,
        refresh_with_cookie(user_id, &pair(&set_cookie), &[WEB]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(refreshed.get("refresh_token").is_none());
    let rotated = cookie_header(&headers);
    assert_ne!(cookie_token(&rotated), cookie_token(&set_cookie));
    assert!(rotated.contains("HttpOnly") && rotated.contains("Path=/auth/refresh"));

    // Using the new access token confirms the rotation, so the spent value is now a leak.
    let access = refreshed["access_token"].as_str().unwrap();
    let (confirmed, _, _) = send(
        &app,
        support::app::request_bearer("GET", "/devices", access),
    )
    .await;
    assert_eq!(confirmed, StatusCode::OK);
    let (replayed, _, _) = send(
        &app,
        refresh_with_cookie(user_id, &pair(&set_cookie), &[WEB]),
    )
    .await;
    assert_eq!(replayed, StatusCode::UNAUTHORIZED);
    let (after, _, _) = send(&app, refresh_with_cookie(user_id, &pair(&rotated), &[WEB])).await;
    assert_eq!(after, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_cookie_refresh_without_the_custom_header_is_refused() {
    let (app, _guard) = app("slimm-web-cookie-csrf").await;
    let (body, set_cookie) = web_register(&app, "csrf").await;
    let user_id = body["user_id"].as_str().unwrap();

    // A cross-site form post carries the cookie but cannot add the header.
    let (status, headers, _) =
        send(&app, refresh_with_cookie(user_id, &pair(&set_cookie), &[])).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(headers.get(SET_COOKIE).is_none());

    // The refused attempt left the cookie usable.
    let (ok, _, _) = send(
        &app,
        refresh_with_cookie(user_id, &pair(&set_cookie), &[WEB]),
    )
    .await;
    assert_eq!(ok, StatusCode::OK);
}

#[tokio::test]
async fn a_cookie_refresh_without_an_account_or_cookie_is_unauthorized() {
    let (app, _guard) = app("slimm-web-cookie-missing").await;
    let (body, set_cookie) = web_register(&app, "missing").await;
    let user_id = body["user_id"].as_str().unwrap();

    let no_account = post("/auth/refresh", &[WEB], json!({}));
    let mut with_cookie = no_account;
    with_cookie
        .headers_mut()
        .insert(COOKIE, pair(&set_cookie).parse().unwrap());
    assert_eq!(send(&app, with_cookie).await.0, StatusCode::UNAUTHORIZED);

    let no_cookie = post(
        "/auth/refresh",
        &[WEB, ("x-slimm-account", user_id)],
        json!({}),
    );
    let (status, headers, _) = send(&app, no_cookie).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(cookie_header(&headers).contains("Max-Age=0"));
}

#[tokio::test]
async fn another_accounts_cookie_never_refreshes_this_account() {
    let (app, store, _guard) = app_with_store("slimm-web-cookie-accounts").await;
    let (alice, alice_cookie) = web_register(&app, "alice").await;
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    store.create_account("bobby", "Bobby", &hash).await.unwrap();
    let login = json!({"username": "bobby", "password": PASSWORD, "device_name": "b"});
    let (_, headers, bob) = send(&app, post("/auth/login", &[WEB], login)).await;
    let bob_cookie = cookie_header(&headers);
    let (alice_id, bob_id) = (
        alice["user_id"].as_str().unwrap(),
        bob["user_id"].as_str().unwrap(),
    );
    assert_ne!(
        pair(&alice_cookie).split('=').next(),
        pair(&bob_cookie).split('=').next()
    );

    let jar = format!("{}; {}", pair(&alice_cookie), pair(&bob_cookie));
    let (_, _, refreshed) = send(&app, refresh_with_cookie(alice_id, &jar, &[WEB])).await;
    assert_eq!(refreshed["user_id"], alice_id);
    let (_, _, refreshed) = send(&app, refresh_with_cookie(bob_id, &jar, &[WEB])).await;
    assert_eq!(refreshed["user_id"], bob_id);
}

#[tokio::test]
async fn sign_out_clears_the_cookie_and_revokes_the_session() {
    let (app, _guard) = app("slimm-web-cookie-logout").await;
    let (body, set_cookie) = web_register(&app, "leaver").await;
    let (user_id, access) = (
        body["user_id"].as_str().unwrap(),
        body["access_token"].as_str().unwrap(),
    );

    let mut logout = support::app::request_bearer("POST", "/auth/logout", access);
    logout.headers_mut().insert(WEB.0, WEB.1.parse().unwrap());
    let (status, headers, _) = send(&app, logout).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let cleared = cookie_header(&headers);
    assert!(
        cleared.starts_with(&format!("__Secure-slimm_rt_{user_id}=;")),
        "{cleared}"
    );
    assert!(cleared.contains("Max-Age=0") && cleared.contains("Path=/auth/refresh"));

    let (after, _, _) = send(
        &app,
        refresh_with_cookie(user_id, &pair(&set_cookie), &[WEB]),
    )
    .await;
    assert_eq!(after, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn removing_the_current_device_clears_the_cookie() {
    let (app, _guard) = app("slimm-web-cookie-device").await;
    let (body, _) = web_register(&app, "devicer").await;
    let access = body["access_token"].as_str().unwrap();
    let (_, _, devices) = send(
        &app,
        support::app::request_bearer("GET", "/devices", access),
    )
    .await;
    let current = devices
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["is_current"] == true)
        .unwrap();

    let mut remove = support::app::request_bearer(
        "DELETE",
        &format!("/devices/{}", current["id"].as_str().unwrap()),
        access,
    );
    remove.headers_mut().insert(WEB.0, WEB.1.parse().unwrap());
    let (status, headers, _) = send(&app, remove).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(cookie_header(&headers).contains("Max-Age=0"));
}

#[tokio::test]
async fn the_non_web_flow_is_unchanged() {
    let (app, _guard) = app("slimm-web-cookie-native").await;
    let (status, headers, body) =
        send(&app, post("/auth/register", &[], register_body("native"))).await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers.get(SET_COOKIE).is_none());
    let refresh = body["refresh_token"].as_str().unwrap().to_owned();

    // A cookie alone does nothing for a client that did not ask for the cookie flow.
    let mut cookie_only = post("/auth/refresh", &[], json!({}));
    cookie_only
        .headers_mut()
        .insert(COOKIE, "a=b".parse().unwrap());
    assert_eq!(send(&app, cookie_only).await.0, StatusCode::BAD_REQUEST);

    let (status, headers, rotated) = send(
        &app,
        post("/auth/refresh", &[], json!({"refresh_token": refresh})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(headers.get(SET_COOKIE).is_none());
    assert!(
        rotated["refresh_token"]
            .as_str()
            .is_some_and(|t| t != refresh)
    );

    let access = rotated["access_token"].as_str().unwrap();
    let (confirmed, _, _) = send(
        &app,
        support::app::request_bearer("GET", "/devices", access),
    )
    .await;
    assert_eq!(confirmed, StatusCode::OK);
    let (denied, headers, _) = send(
        &app,
        post("/auth/refresh", &[], json!({"refresh_token": refresh})),
    )
    .await;
    assert_eq!(denied, StatusCode::UNAUTHORIZED);
    assert!(headers.get(SET_COOKIE).is_none());
}

#[tokio::test]
async fn a_body_token_with_the_web_header_migrates_to_the_cookie() {
    let (app, _guard) = app("slimm-web-cookie-migrate").await;
    let (_, _, body) = send(&app, post("/auth/register", &[], register_body("migrant"))).await;
    let old = body["refresh_token"].as_str().unwrap();

    let (status, headers, rotated) = send(
        &app,
        post("/auth/refresh", &[WEB], json!({"refresh_token": old})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(rotated.get("refresh_token").is_none());
    assert!(cookie_header(&headers).contains("HttpOnly"));
}

#[tokio::test]
async fn completing_a_second_factor_sets_the_cookie_too() {
    use crate::totp_support as totp;

    let (store, auth, _guard) = totp::new_store("slimm-web-cookie-totp").await;
    let app = totp::app(store.clone(), auth.clone());
    let (token, _id) = totp::member(&store, &auth, "factor").await;
    let (_secret, codes) = totp::enrol_and_confirm(&app, &token).await;
    let challenge = totp::login_for_challenge(&app, "factor").await;

    let verify = post(
        "/auth/totp/verify",
        &[WEB],
        json!({"challenge": challenge, "code": codes[0]}),
    );
    let (status, headers, body) = send(&app, verify).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.get("refresh_token").is_none());
    assert!(cookie_header(&headers).contains("HttpOnly"));
}
