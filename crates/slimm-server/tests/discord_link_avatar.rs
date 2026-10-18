// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The picture copied from a linked Discord account: stored at link time,
//! served by this server alone, and gone with the link or the account.

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use axum::http::{Request, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Extension, Json, Router};
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::http::linked_accounts::DiscordLinks;
use slimm_server::http::{self};
use slimm_server::media::Media;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::json_body;

const REDIRECT: &str = "https://slim.example/links/discord/callback";
const PASSWORD: &str = "correct-horse-battery";
const DISCORD_ID: &str = "80351110224678912";

#[derive(Clone)]
enum Picture {
    Absent,
    Served(&'static str, Vec<u8>),
}

async fn fake_discord(picture: Picture) -> String {
    let hash = match picture {
        Picture::Absent => json!(null),
        Picture::Served(..) => json!("a1b2c3"),
    };
    let app = Router::new()
        .route(
            "/oauth2/token",
            post(|| async { Json(json!({ "access_token": "fake-token" })) }),
        )
        .route(
            "/users/@me",
            get(move || async move {
                Json(json!({
                    "id": DISCORD_ID, "username": "ada", "global_name": "Ada L", "avatar": hash,
                }))
            }),
        )
        .route(
            "/avatars/{id}/{file}",
            get(move || {
                let picture = picture.clone();
                async move {
                    match picture {
                        Picture::Served(kind, bytes) => {
                            ([(CONTENT_TYPE, kind)], bytes).into_response()
                        }
                        Picture::Absent => StatusCode::NOT_FOUND.into_response(),
                    }
                }
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://{addr}")
}

struct World {
    app: Router,
    store: Store,
    media_root: std::path::PathBuf,
    ada: slimm_server::ids::UserId,
    ada_token: String,
    bob_token: String,
    _guards: (support::TestDbGuard, support::TestDirGuard),
}

async fn world(picture: Picture) -> World {
    let (store, db_guard) = support::new_store("slimm-discord-avatar").await;
    let (root, dir_guard) = support::TestDirGuard::new("slimm-discord-avatar-media");
    let media = Media::new(&root, 10 * 1024 * 1024).unwrap();
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let admin = store.create_account("root", "Root", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let ada = store.create_account("ada", "Ada", &hash).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let ada_token = store.open_session(ada.id, "x").await.unwrap().access_token;
    let bob_token = store.open_session(bob.id, "y").await.unwrap().access_token;
    let api = fake_discord(picture).await;
    let discord = DiscordLinks::with_api("client-1", "secret-1", REDIRECT, &api).unwrap();
    let app = http::router(support::app::builder(store.clone()).media(media).build())
        .layer(Extension(discord));
    World {
        app,
        store,
        media_root: root,
        ada: ada.id,
        ada_token,
        bob_token,
        _guards: (db_guard, dir_guard),
    }
}

fn get_as(uri: &str, token: &str, method: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

impl World {
    async fn status(&self, method: &str, uri: &str, token: &str) -> StatusCode {
        self.send(method, uri, token).await.status()
    }

    async fn send(&self, method: &str, uri: &str, token: &str) -> axum::response::Response {
        self.app
            .clone()
            .oneshot(get_as(uri, token, method))
            .await
            .unwrap()
    }

    async fn link(&self) {
        let start = self
            .send("POST", "/me/links/discord/start", &self.ada_token)
            .await;
        let url = url::Url::parse(json_body(start).await["url"].as_str().unwrap()).unwrap();
        let state = url
            .query_pairs()
            .find(|(key, _)| key == "state")
            .unwrap()
            .1
            .into_owned();
        let callback = self
            .app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/links/discord/callback?code=c&state={state}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(callback.status(), StatusCode::OK);
    }

    fn avatar_uri(&self) -> String {
        format!("/users/{}/links/discord/avatar", self.ada)
    }

    fn stored_file(&self) -> std::path::PathBuf {
        self.media_root
            .join("avatars")
            .join(format!("link-discord-{}", self.ada))
    }

    async fn listed_marker(&self) -> serde_json::Value {
        let listed = self
            .send(
                "GET",
                &format!("/users/{}/links", self.ada),
                &self.bob_token,
            )
            .await;
        json_body(listed).await[0]["avatar_updated_at"].clone()
    }
}

#[tokio::test]
async fn the_picture_is_stored_at_link_time_and_served_to_others() {
    let picture = support::images::small_png();
    let w = world(Picture::Served("image/png", picture.clone())).await;
    w.link().await;

    assert!(w.stored_file().exists());
    assert!(w.listed_marker().await.as_i64().is_some());
    let served = w.send("GET", &w.avatar_uri(), &w.bob_token).await;
    assert_eq!(served.status(), StatusCode::OK);
    assert_eq!(served.headers()[CONTENT_TYPE], "image/png");
    let body = axum::body::to_bytes(served.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(body.as_ref(), picture.as_slice());
}

#[tokio::test]
async fn an_account_with_no_custom_picture_stores_nothing() {
    let w = world(Picture::Absent).await;
    w.link().await;

    assert!(!w.stored_file().exists());
    assert!(w.listed_marker().await.is_null());
    assert_eq!(
        w.status("GET", &w.avatar_uri(), &w.bob_token).await,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn a_response_that_is_not_a_still_image_is_refused_but_the_link_stands() {
    let oversized = support::images::png(16, 16, &vec![0; 2 * 1024 * 1024]);
    let refused = [
        Picture::Served("text/html", b"<html></html>".to_vec()),
        Picture::Served("image/png", b"not really a png".to_vec()),
        Picture::Served("image/gif", support::images::animated_gif()),
        Picture::Served("image/png", oversized),
    ];
    for picture in refused {
        let w = world(picture).await;
        w.link().await;

        assert!(!w.stored_file().exists());
        assert!(w.listed_marker().await.is_null());
        let mine = w.send("GET", "/me/links", &w.ada_token).await;
        assert_eq!(json_body(mine).await[0]["username"], "ada");
    }
}

#[tokio::test]
async fn unlinking_deletes_the_stored_picture() {
    let w = world(Picture::Served("image/png", support::images::small_png())).await;
    w.link().await;
    assert!(w.stored_file().exists());

    assert_eq!(
        w.status("DELETE", "/me/links/discord", &w.ada_token).await,
        StatusCode::NO_CONTENT
    );
    assert!(!w.stored_file().exists());
    assert_eq!(
        w.status("GET", &w.avatar_uri(), &w.bob_token).await,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn deleting_the_account_removes_the_stored_picture() {
    let w = world(Picture::Served("image/png", support::images::small_png())).await;
    w.link().await;
    assert!(w.stored_file().exists());

    let deleted = w
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {}", w.ada_token))
                .header("content-type", "application/json")
                .body(Body::from(format!(r#"{{"password":"{PASSWORD}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    assert!(!w.stored_file().exists());
    assert!(w.store.linked_accounts(w.ada).await.unwrap().is_empty());
}
