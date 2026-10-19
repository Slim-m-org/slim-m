// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP integration tests for profile banners: upload, fetch and delete, with
//! a gif allowed where an avatar must be still (decision 0074).

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::auth::Auth;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body};

fn request_bytes(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

const PASSWORD: &str = "correct-horse-battery";

fn request_plain(method: &str, uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn register(store: &Store, username: &str) -> String {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

fn png(padding: usize) -> Vec<u8> {
    let mut bytes = support::images::small_png();
    bytes.extend(std::iter::repeat_n(0u8, padding));
    bytes
}

async fn ready(prefix: &str) -> (axum::Router, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store(prefix).await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    let id = me["id"].as_str().unwrap().to_owned();
    (app, token, id, guard)
}

#[tokio::test]
async fn a_banner_is_reflected_on_the_profile_and_is_fetchable() {
    let (app, token, id, _guard) = ready("slimm-banners-upload").await;

    let uploaded = app
        .clone()
        .oneshot(request_bytes("POST", "/me/banner", &token, png(8)))
        .await
        .unwrap();
    assert_eq!(uploaded.status(), StatusCode::OK);
    let uploaded = json_body(uploaded).await;
    assert!(uploaded["banner_updated_at"].is_i64());
    assert!(
        uploaded["avatar_updated_at"].is_null(),
        "a banner is not an avatar"
    );

    let fetched = app
        .clone()
        .oneshot(request_plain("GET", &format!("/users/{id}/banner"), &token))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::OK);
    assert_eq!(fetched.headers().get("content-type").unwrap(), "image/png");
}

#[tokio::test]
async fn a_gif_banner_is_accepted_where_an_avatar_gif_is_not() {
    let (app, token, id, _guard) = ready("slimm-banners-gif").await;
    let gif = support::images::animated_gif();

    let avatar = app
        .clone()
        .oneshot(request_bytes("POST", "/me/avatar", &token, gif.clone()))
        .await
        .unwrap();
    let banner = app
        .clone()
        .oneshot(request_bytes("POST", "/me/banner", &token, gif))
        .await
        .unwrap();

    assert_eq!(avatar.status(), StatusCode::BAD_REQUEST);
    assert_eq!(banner.status(), StatusCode::OK);
    let fetched = app
        .oneshot(request_plain("GET", &format!("/users/{id}/banner"), &token))
        .await
        .unwrap();
    assert_eq!(fetched.headers().get("content-type").unwrap(), "image/gif");
}

#[tokio::test]
async fn removing_a_banner_returns_to_the_colour() {
    let (app, token, id, _guard) = ready("slimm-banners-delete").await;
    app.clone()
        .oneshot(request_bytes("POST", "/me/banner", &token, png(8)))
        .await
        .unwrap();

    let deleted = app
        .clone()
        .oneshot(request_plain("DELETE", "/me/banner", &token))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    assert!(me["banner_updated_at"].is_null());
    let fetched = app
        .oneshot(request_plain("GET", &format!("/users/{id}/banner"), &token))
        .await
        .unwrap();
    assert_eq!(fetched.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_non_image_banner_is_refused() {
    let (app, token, _id, _guard) = ready("slimm-banners-refuse").await;

    let response = app
        .oneshot(request_bytes(
            "POST",
            "/me/banner",
            &token,
            b"%PDF-1.7 not really a pdf".to_vec(),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn deleting_an_account_removes_its_banner_file() {
    let (store, _guard) = support::new_store("slimm-banners-account-delete").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let (root, _media_guard) = support::TestDirGuard::new("slimm-banners-account-delete");
    let media = Media::new(&root, 10 * 1024 * 1024).expect("create temp media directories");
    let app = support::app::builder(store.clone()).media(media).router();
    let token = register(&store, "alice").await;
    let me = json_body(
        app.clone()
            .oneshot(request_plain("GET", "/me", &token))
            .await
            .unwrap(),
    )
    .await;
    let user_id = me["id"].as_str().unwrap().to_owned();
    app.clone()
        .oneshot(request_bytes("POST", "/me/banner", &token, png(8)))
        .await
        .unwrap();
    let file = root.join("avatars").join(format!("banner-{user_id}"));
    assert!(file.exists(), "the upload landed on disk");

    let deleted = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(format!(r#"{{"password":"{PASSWORD}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    assert!(
        !file.exists(),
        "the banner file must not outlive the account"
    );
}
