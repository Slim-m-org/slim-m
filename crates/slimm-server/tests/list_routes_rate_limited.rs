// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /categories` and `GET /channels` took a bare `Authed` with no rate
//! limit charged at all, unlike every sibling handler in their own files -
//! the same previously-uncharged-route shape `resource_bounds.rs` already
//! found and fixed for `/sync`, the read marker, invites, reports and
//! presence. Split into its own file rather than added to that one so its
//! own "eight routes" count in its doc comment stays accurate.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

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

fn app(store: Store) -> Router {
    support::app::builder(store)
        .limiter(RateLimiter::with_trusted_hops(0))
        .router()
}

async fn member(store: &Store, username: &str) -> String {
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

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// `AuthedRead`'s burst is 40 (`ratelimit/class.rs`), so a run well past it
/// is refused if the route charges anything at all.
#[tokio::test]
async fn channel_and_category_lists_charge_a_rate_limit() {
    let (store, _guard) = new_store("slimm-list-routes-rate-limited").await;
    let token = member(&store, "alice").await;
    let app = app(store);

    for uri in ["/channels", "/categories"] {
        let mut throttled = false;
        for _ in 0..45 {
            let response = app.clone().oneshot(get(uri, &token)).await.unwrap();
            if response.status() == StatusCode::TOO_MANY_REQUESTS {
                throttled = true;
                break;
            }
        }
        assert!(throttled, "GET {uri} charges no rate limit");
    }
}
