// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a selected GIF may be, how big, and where it may come from: the
//! admin's size cap, the storage ceiling under concurrency, the allowed
//! content types, redirects, and the select rate.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use futures_util::future::join_all;
use serde_json::{Value, json};
use slimm_server::http::gifs::GifSearch;
use slimm_server::ids::UserId;
use slimm_server::media::Media;
use slimm_server::ratelimit::{Class, RateLimiter};
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tower::ServiceExt;

use crate::support;
use support::app::json_body;

fn gif(padding: usize, tag: u8) -> Vec<u8> {
    let mut bytes = b"GIF89a".to_vec();
    bytes.extend(std::iter::repeat_n(tag, padding));
    bytes
}

#[derive(Clone)]
struct Fake {
    base: String,
    full: Arc<dyn Fn(u8) -> Response + Send + Sync>,
    served: Arc<AtomicU8>,
}

async fn search(State(fake): State<Fake>) -> axum::Json<Value> {
    let base = &fake.base;
    axum::Json(json!({
        "next": "",
        "results": [{
            "id": "1",
            "content_description": "a cat",
            "media_formats": {
                "tinygif": {"url": format!("{base}/preview.gif"), "dims": [10, 10], "size": 1},
                "gif": {"url": format!("{base}/full.gif"), "dims": [10, 10], "size": 2}
            }
        }]
    }))
}

async fn full(State(fake): State<Fake>) -> Response {
    let n = fake.served.fetch_add(1, Ordering::SeqCst);
    (fake.full)(n)
}

async fn spawn(full_body: impl Fn(u8) -> Response + Send + Sync + 'static) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let fake = Fake {
        base: base.clone(),
        full: Arc::new(full_body),
        served: Arc::new(AtomicU8::new(0)),
    };
    let router = Router::new()
        .route("/v2/search", get(search))
        .route("/preview.gif", get(|| async { gif(8, 0) }))
        .route("/full.gif", get(full))
        .with_state(fake);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    base
}

fn bytes_of(body: Vec<u8>) -> Response {
    body.into_response()
}

struct Harness {
    app: Router,
    token: String,
    user: UserId,
    store: Store,
    _guard: support::TestDbGuard,
}

async fn harness(
    prefix: &str,
    base: &str,
    media: Media,
    limiter: RateLimiter,
    admin_cap: Option<u64>,
) -> Harness {
    let (store, guard) = support::new_store(prefix).await;
    let account = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    if let Some(cap) = admin_cap {
        store.set_attachment_max_bytes(cap).await.unwrap();
    }
    let app = support::app::builder(store.clone())
        .gifs(GifSearch::for_test("tenor", base, "k"))
        .media(media)
        .limiter(limiter)
        .router();
    Harness {
        app,
        token,
        user: account.id,
        store,
        _guard: guard,
    }
}

impl Harness {
    async fn search_token(&self) -> String {
        let response = self
            .app
            .clone()
            .oneshot(self.request("GET", "/gifs/search?q=cat", None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        json_body(response).await["results"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn request(&self, method: &str, uri: &str, body: Option<Value>) -> Request<Body> {
        let builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token));
        match body {
            Some(body) => builder
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(body.to_string())),
            None => builder.body(Body::empty()),
        }
        .unwrap()
    }

    async fn select(&self, id: &str) -> StatusCode {
        let request = self.request("POST", "/gifs/select", Some(json!({ "id": id })));
        self.app.clone().oneshot(request).await.unwrap().status()
    }

    async fn stored_bytes(&self) -> i64 {
        self.store.total_attachment_bytes().await.unwrap()
    }
}

#[tokio::test]
async fn a_gif_over_the_admins_attachment_cap_is_refused() {
    let base = spawn(|_| bytes_of(gif(200, 1))).await;
    let h = harness(
        "slimm-gif-admin-cap",
        &base,
        Media::for_tests(),
        RateLimiter::new(),
        Some(64),
    )
    .await;
    let id = h.search_token().await;
    assert_ne!(h.select(&id).await, StatusCode::CREATED);
    assert_eq!(h.stored_bytes().await, 0);
}

#[tokio::test]
async fn a_text_or_png_payload_from_a_provider_is_refused() {
    let png = support::images::small_png();
    for (prefix, payload) in [
        ("slimm-gif-text", b"just some plain text".to_vec()),
        ("slimm-gif-png", png),
    ] {
        let base = spawn(move |_| bytes_of(payload.clone())).await;
        let h = harness(prefix, &base, Media::for_tests(), RateLimiter::new(), None).await;
        let id = h.search_token().await;
        assert_eq!(h.select(&id).await, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(h.stored_bytes().await, 0);
    }
}

#[tokio::test]
async fn concurrent_selects_cannot_overshoot_the_storage_ceiling() {
    let size = gif(100, 0).len() as u64;
    let base = spawn(|n| bytes_of(gif(100, n + 1))).await;
    let media = Media::for_tests().with_total_ceiling(Some(size * 2));
    let h = harness("slimm-gif-ceiling", &base, media, RateLimiter::new(), None).await;
    let id = h.search_token().await;
    let statuses = join_all((0..8).map(|_| h.select(&id))).await;
    let created = statuses
        .iter()
        .filter(|status| **status == StatusCode::CREATED)
        .count();
    assert!(created <= 2, "{created} selects fit a ceiling of two");
    assert!(h.stored_bytes().await as u64 <= size * 2);
}

#[tokio::test]
async fn a_redirect_off_the_provider_host_is_not_followed() {
    let target = spawn(|_| bytes_of(gif(10, 9))).await;
    let location = format!("{target}/full.gif");
    let base =
        spawn(move |_| (StatusCode::FOUND, [(header::LOCATION, location.clone())]).into_response())
            .await;
    let h = harness(
        "slimm-gif-redirect",
        &base,
        Media::for_tests(),
        RateLimiter::new(),
        None,
    )
    .await;
    let id = h.search_token().await;
    assert_eq!(h.select(&id).await, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(h.stored_bytes().await, 0);
}

#[tokio::test]
async fn a_select_spends_its_own_budget_not_the_upload_one() {
    let base = spawn(|_| bytes_of(gif(10, 3))).await;
    let limiter = RateLimiter::new();
    let h = harness(
        "slimm-gif-budget",
        &base,
        Media::for_tests(),
        limiter.clone(),
        None,
    )
    .await;
    let id = h.search_token().await;
    let key = format!("u:{}", h.user);
    assert!(limiter.admit_weighted(Class::Upload, &key, 10.0).is_ok());
    assert_ne!(h.select(&id).await, StatusCode::TOO_MANY_REQUESTS);
    assert!(limiter.admit_weighted(Class::GifSelect, &key, 19.0).is_ok());
    assert_eq!(h.select(&id).await, StatusCode::TOO_MANY_REQUESTS);
}
