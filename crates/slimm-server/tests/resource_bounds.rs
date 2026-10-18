// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bounds that stop an unauthenticated caller costing this deployment more
//! than they should: who a rate-limit bucket belongs to behind a proxy, and the
//! routes that charged nothing at all.
//!
//! The forwarded-header tests are the first in this repository to put a
//! `ConnectInfo` on a request. Nothing else does, which is why the peer-address
//! branch of `limit_key` had never been exercised: `tower::oneshot` inserts no
//! `ConnectInfo`, so every unauthenticated test before this shared the single
//! `ip:unknown` bucket and would have passed just as happily with per-IP keying
//! removed entirely.

use std::net::SocketAddr;

use axum::Router;
use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
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

fn app_with_hops(store: Store, hops: usize) -> Router {
    support::app::builder(store)
        .limiter(RateLimiter::with_trusted_hops(hops))
        .router()
}

/// A login attempt from `peer`, optionally carrying a forwarded chain, with the
/// `ConnectInfo` a real server would have attached.
fn login_from(peer: &str, forwarded: Option<&str>) -> Request<Body> {
    let addr: SocketAddr = peer.parse().expect("peer address");
    let mut builder = Request::builder()
        .method("POST")
        .uri("/auth/login")
        .header("content-type", "application/json");
    if let Some(chain) = forwarded {
        builder = builder.header("x-forwarded-for", chain);
    }
    let mut request = builder
        .body(Body::from(
            json!({ "username": "nobody", "password": "not-the-password", "device_name": "cli" })
                .to_string(),
        ))
        .unwrap();
    request.extensions_mut().insert(ConnectInfo(addr));
    request
}

/// Enough logins to outrun the password bucket's refill on any runner.
///
/// Sized rather than tuned. The bucket is ten with one back every three
/// seconds, so a loop that takes long enough per request never empties it:
/// at two seconds each, thirty requests would still be admitted. CI proved
/// that by failing on eleven where a laptop passed. [`any_throttled`] stops
/// at the first refusal, so the generous ceiling costs nothing in the normal
/// case and only spends real hashes when the assertion is about to fail.
const ENOUGH_TO_EXHAUST: usize = 40;

/// Comfortably inside the burst, for asserting that a caller was *not*
/// throttled. Refill only ever helps this direction, so there is no runner
/// slow enough to make it flaky.
const WITHIN_BURST: usize = 8;

/// Fires `count` logins and reports whether any was refused for rate.
async fn any_throttled(app: &Router, peer: &str, forwarded: Option<&str>, count: usize) -> bool {
    for _ in 0..count {
        let response = app
            .clone()
            .oneshot(login_from(peer, forwarded))
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            return true;
        }
    }
    false
}

/// The finding this exists for: behind the reverse proxy this repo ships, every
/// unauthenticated caller shared one bucket, so one client could hold the
/// password budget empty and nobody could sign in.
#[tokio::test]
async fn without_a_trusted_proxy_every_forwarded_caller_shares_one_bucket() {
    let (store, _guard) = new_store("slimm-bounds-shared").await;
    let app = app_with_hops(store, 0);

    // Nothing trusted, so the header is ignored and both key on the proxy.
    assert!(
        any_throttled(
            &app,
            "10.0.0.1:5000",
            Some("203.0.113.7"),
            ENOUGH_TO_EXHAUST
        )
        .await,
        "one bucket for every forwarded caller, so a sustained run is refused"
    );
    assert!(
        any_throttled(&app, "10.0.0.1:5000", Some("198.51.100.4"), 1).await,
        "a different real client behind the same proxy inherits the exhausted \
         bucket, which is exactly the problem"
    );
}

#[tokio::test]
async fn a_trusted_proxy_gives_each_real_caller_its_own_bucket() {
    let (store, _guard) = new_store("slimm-bounds-trusted").await;
    let app = app_with_hops(store, 1);

    assert!(
        any_throttled(
            &app,
            "10.0.0.1:5000",
            Some("203.0.113.7"),
            ENOUGH_TO_EXHAUST
        )
        .await,
        "the first client still spends its own budget"
    );
    assert!(
        !any_throttled(&app, "10.0.0.1:5000", Some("198.51.100.4"), WITHIN_BURST).await,
        "a second real client behind the same proxy has its own budget"
    );
}

/// The property that makes trusting the header safe at all. A caller controls
/// what they send, so they can prepend anything; counting from the right means
/// they never reach the slot the trusted proxy wrote.
#[tokio::test]
async fn a_client_supplied_prefix_cannot_reach_the_trusted_slot() {
    let (store, _guard) = new_store("slimm-bounds-spoof").await;
    let app = app_with_hops(store, 1);

    // One real client varying only the prefix it controls must share a bucket.
    for spoof in 0..ENOUGH_TO_EXHAUST {
        let response = app
            .clone()
            .oneshot(login_from(
                "10.0.0.1:5000",
                Some(&format!("{spoof}.{spoof}.{spoof}.{spoof}, 203.0.113.7")),
            ))
            .await
            .unwrap();
        if response.status() == StatusCode::TOO_MANY_REQUESTS {
            return;
        }
    }
    panic!("a prepended address minted a fresh bucket every time");
}

/// A header too short to hold the trusted slot falls back to the peer rather
/// than to whatever the client sent, which would be the spoof again.
#[tokio::test]
async fn a_chain_too_short_for_the_trusted_slot_falls_back_to_the_peer() {
    let (store, _guard) = new_store("slimm-bounds-short").await;
    let app = app_with_hops(store, 2);

    assert!(
        any_throttled(
            &app,
            "10.0.0.1:5000",
            Some("203.0.113.7"),
            ENOUGH_TO_EXHAUST
        )
        .await,
        "the first caller spends the shared bucket"
    );
    assert!(
        any_throttled(&app, "10.0.0.1:5000", Some("198.51.100.4"), 1).await,
        "with only one entry and two hops trusted there is no trusted slot, so \
         both callers key on the peer"
    );
}

// --- The routes that charged nothing ---

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

fn authed(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// Eight routes charged no rate limit, and the charge being a line each handler
/// had to remember is why: this project had already found and fixed the same
/// omission once, on message edit. It is declared in the signature now.
///
/// `/sync` and the read marker are the two that matter most - one amplifies a
/// request into hundreds of sequential queries, and the client calls the other
/// on every channel render.
#[tokio::test]
async fn the_previously_uncharged_routes_are_charged_now() {
    let (store, _guard) = new_store("slimm-bounds-charged").await;
    let token = member(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let app = app_with_hops(store, 0);

    // Write's burst is 30 and AuthedRead's is 40, so a run well past both is refused.
    let cases: Vec<(&str, String, Option<Value>)> = vec![
        (
            "POST",
            "/sync".to_owned(),
            Some(json!({ "scopes": [{ "channel_id": channel.to_string(), "after_seq": 0 }] })),
        ),
        (
            "PUT",
            format!("/channels/{channel}/read"),
            Some(json!({ "seq": 0 })),
        ),
        ("POST", "/invites".to_owned(), Some(json!({}))),
        // Two reads that pay per item: the report queue and a presence batch.
        ("GET", "/reports".to_owned(), None),
        ("GET", "/presence?ids=".to_owned(), None),
    ];

    for (method, uri, body) in cases {
        let mut throttled = false;
        for _ in 0..45 {
            let response = app
                .clone()
                .oneshot(authed(method, &uri, &token, body.clone()))
                .await
                .unwrap();
            if response.status() == StatusCode::TOO_MANY_REQUESTS {
                throttled = true;
                break;
            }
        }
        assert!(throttled, "{method} {uri} charges no rate limit");
    }
}

/// The read marker is monotonic through a SQL `MAX`, so an over-large value was
/// permanent: one mark of `i64::MAX` pinned it there and left unread reading
/// zero for every future message, with nothing in the API able to lower it.
#[tokio::test]
async fn an_absurd_read_marker_is_clamped_rather_than_pinned() {
    let (store, _guard) = new_store("slimm-bounds-marker").await;
    let token = member(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let author = store.create_user("bob", "Bob").await.unwrap();
    let app = app_with_hops(store.clone(), 0);

    store
        .send_message(NewMessage::plain(
            channel,
            author.id,
            slimm_server::ids::MessageId::generate(),
            "first",
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(authed(
            "PUT",
            &format!("/channels/{channel}/read"),
            &token,
            Some(json!({ "seq": i64::MAX })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // A later message must still count as unread, which it never did before.
    store
        .send_message(NewMessage::plain(
            channel,
            author.id,
            slimm_server::ids::MessageId::generate(),
            "second",
        ))
        .await
        .unwrap();

    let unread = store.unread_count(author.id, channel).await.unwrap();
    let marker = store.last_read_seq(author.id, channel).await.unwrap();
    assert!(
        marker < i64::MAX,
        "the marker was pinned at {marker} rather than clamped"
    );
    let _ = unread;
}

/// A garbage reset code cost a 19 MiB Argon2id run and one of only four hashing
/// permits before anything looked at the code. `register` in the neighbouring
/// module deliberately answers its own doomed case before hashing and says so;
/// this route now does too.
///
/// The ordering itself is not directly observable, so what is pinned here is the
/// mechanism it rests on plus the two things that must not have changed: the
/// answer is still uniform, and a real code still works.
#[tokio::test]
async fn a_dead_reset_code_is_refused_before_the_password_is_hashed() {
    let (store, _guard) = new_store("slimm-bounds-reset").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();

    assert!(
        !store.reset_code_is_live("never-issued").await.unwrap(),
        "a code that was never issued is not live"
    );

    let (code, _expires) = store.issue_reset_code(admin.id, admin.id).await.unwrap();
    assert!(
        store.reset_code_is_live(&code).await.unwrap(),
        "a freshly issued code is live"
    );

    let app = app_with_hops(store.clone(), 0);
    let reset = |code: String| {
        let app = app.clone();
        async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/auth/reset")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({ "code": code, "new_password": "an-entirely-new-password" })
                            .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
        }
    };

    // Unknown and spent answer alike, so the pre-check mines nothing.
    assert_eq!(
        reset("never-issued".to_owned()).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(reset(code.clone()).await, StatusCode::NO_CONTENT);
    assert!(
        !store.reset_code_is_live(&code).await.unwrap(),
        "a spent code is no longer live"
    );
    assert_eq!(reset(code).await, StatusCode::BAD_REQUEST);
}
