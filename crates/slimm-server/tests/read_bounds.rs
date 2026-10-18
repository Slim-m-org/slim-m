// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The pin set's write-time ceiling, and the DM narrowing in the batched
//! viewer check.
//!
//! Neither was reachable without a permission, so neither is a way in from
//! outside. What they are is a cost that scales with how much members have
//! done rather than with anything an operator chose, which is the same shape as
//! the unauthenticated bounds in `resource_bounds.rs` one privilege level up.
//! The moderation queue's half is in `report_paging.rs`.
//!
//! Its own file rather than added to `pins.rs` (433 lines): that one is past the
//! review budget already.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::{MAX_PINS_PER_CHANNEL, NewMessage, PinError, Store};
use tower::ServiceExt;

mod support;

use support::app::app;

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

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn json_array(app: &Router, uri: &str, token: &str) -> Vec<Value> {
    let response = app.clone().oneshot(get(uri, token)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK, "GET {uri}");
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// An administrator with a session, and the deployment claimed by them.
async fn admin(store: &Store, username: &str) -> (UserId, String, ChannelId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.list_channels().await.unwrap()[0].id;
    (account.id, token, channel)
}

async fn message(store: &Store, channel: ChannelId, author: UserId, body: &str) -> MessageId {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
        .message
        .id
}

// --- Pins ---

// --- Pins ---

/// A channel's pin set is bounded at the write rather than paged at the read,
/// so every reader can still have all of it. Driven through the store: the
/// point is the ceiling, and 200 pins through HTTP would be 200 round trips to
/// prove the same thing.
#[tokio::test]
async fn a_channel_refuses_a_pin_past_its_ceiling() {
    let (store, _guard) = new_store("slimm-bounds-pin-ceiling").await;
    let (author, _token, channel) = admin(&store, "root").await;

    let mut first = None;
    for index in 0..MAX_PINS_PER_CHANNEL {
        let id = message(&store, channel, author, &format!("m{index}")).await;
        store.pin_message(channel, id, author).await.unwrap();
        if first.is_none() {
            first = Some(id);
        }
    }

    let one_more = message(&store, channel, author, "one too many").await;
    assert!(
        matches!(
            store.pin_message(channel, one_more, author).await,
            Err(PinError::TooMany)
        ),
        "the ceiling must refuse, not silently drop"
    );

    // Idempotence must survive the ceiling, or a retry breaks when it is full.
    store
        .pin_message(channel, first.unwrap(), author)
        .await
        .expect("re-pinning an existing pin is not a new pin");

    assert_eq!(
        store.pin_count(channel).await.unwrap(),
        MAX_PINS_PER_CHANNEL
    );
}

#[tokio::test]
async fn the_pin_list_takes_a_limit() {
    let (store, _guard) = new_store("slimm-bounds-pin-limit").await;
    let (author, token, channel) = admin(&store, "root").await;
    for index in 0..5 {
        let id = message(&store, channel, author, &format!("m{index}")).await;
        store.pin_message(channel, id, author).await.unwrap();
    }

    let uri = format!("/channels/{channel}/pins?limit=2");
    let page = json_array(&app(store.clone()), &uri, &token).await;
    assert_eq!(page.len(), 2);

    let uri = format!("/channels/{channel}/pins");
    let all = json_array(&app(store.clone()), &uri, &token).await;
    assert_eq!(all.len(), 5, "no limit still answers the whole bounded set");
}

/// A DM's viewer check narrows the candidates to the pair before asking
/// anything per candidate. Correctness is already pinned by
/// `permissions.rs`'s equivalence test; what this adds is that a candidate
/// list far longer than the pair is answered the same way, which is the
/// property the two comments in that branch used to claim falsely.
#[tokio::test]
async fn a_dm_viewer_check_ignores_candidates_outside_the_pair() {
    let (store, _guard) = new_store("slimm-bounds-dm-viewers").await;
    let (alice, _token, _channel) = admin(&store, "alice").await;
    let bob = store.create_user("bob", "Bob").await.unwrap();
    let dm = store.open_dm(alice, bob.id).await.unwrap();

    let mut candidates = vec![alice, bob.id];
    for index in 0..20 {
        let stranger = store
            .create_user(&format!("s{index}"), "Stranger")
            .await
            .unwrap();
        candidates.push(stranger.id);
    }

    let viewers = store.viewers_among(dm.id, &candidates).await.unwrap();
    assert_eq!(viewers.len(), 2, "only the pair can view their own DM");
    assert!(viewers.contains(&alice) && viewers.contains(&bob.id));

    let strangers_only: Vec<UserId> = candidates.into_iter().skip(2).collect();
    assert!(
        store
            .viewers_among(dm.id, &strangers_only)
            .await
            .unwrap()
            .is_empty()
    );
}
