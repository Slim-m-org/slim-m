// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel's own retention window, everything left in a deleted channel,
//! and the sweep finishing a large backlog in one tick. See
//! `store/channel_retention.rs` and `store/message_retention.rs`.
use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::media::Media;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use slimm_server::voice::VoiceService;
use sqlx::SqlitePool;
use tower::ServiceExt;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

async fn harness(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(v) => builder
            .header("content-type", "application/json")
            .body(Body::from(v.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A registered account plus a bootstrapped deployment, so `general` exists.
async fn register(store: &Store, username: &str) -> UserId {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    account.id
}

async fn general(store: &Store) -> ChannelId {
    store.list_channels().await.unwrap()[0].id
}

/// Rewrites a message's own `created_at`, the same shape
/// `canvas_ops_sweep.rs`'s own test harness backdates a row with.
async fn backdate_message(pool: &SqlitePool, id: MessageId, created_at: i64) {
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(created_at)
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
}

async fn post(
    store: &Store,
    pool: &SqlitePool,
    channel: ChannelId,
    author: UserId,
    age_days: i64,
) -> MessageId {
    let id = store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    backdate_message(pool, id, now_ms() - age_days * DAY_MS).await;
    id
}

async fn is_live(store: &Store, id: MessageId) -> bool {
    store.message(id).await.unwrap().is_some()
}

#[tokio::test]
async fn a_channel_window_prunes_that_channel_and_its_threads_only() {
    let (s, pool, _guard) = harness("slimm-chan-retention-own").await;
    let admin = register(&s, "root").await;
    let feed = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    let old_feed = post(&s, &pool, feed, admin, 40).await;
    let new_feed = post(&s, &pool, feed, admin, 5).await;
    let old_other = post(&s, &pool, other, admin, 40).await;
    let thread = s.open_thread(feed, new_feed).await.unwrap().channel.id;
    let old_reply = post(&s, &pool, thread, admin, 40).await;
    s.set_channel_retention_days(feed, Some(30)).await.unwrap();

    let swept = s.sweep_message_retention().await.unwrap();

    assert!(!is_live(&s, old_feed).await);
    assert!(
        !is_live(&s, old_reply).await,
        "a thread follows its channel"
    );
    assert!(is_live(&s, new_feed).await);
    assert!(is_live(&s, old_other).await, "the Space window is off");
    assert_eq!(swept.pruned.len(), 2);
}

#[tokio::test]
async fn a_zero_window_keeps_a_channel_the_space_would_prune() {
    let (s, pool, _guard) = harness("slimm-chan-retention-keep").await;
    let admin = register(&s, "root").await;
    let kept = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    let old_kept = post(&s, &pool, kept, admin, 40).await;
    let old_other = post(&s, &pool, other, admin, 40).await;
    s.set_message_retention_days(30).await.unwrap();
    s.set_channel_retention_days(kept, Some(0)).await.unwrap();

    s.sweep_message_retention().await.unwrap();

    assert!(is_live(&s, old_kept).await);
    assert!(!is_live(&s, old_other).await);
}

#[tokio::test]
async fn everything_left_in_a_deleted_channel_is_pruned() {
    let (s, pool, _guard) = harness("slimm-chan-retention-deleted").await;
    let admin = register(&s, "root").await;
    let gone = s.create_channel("gone", "text").await.unwrap().id;
    let fresh = post(&s, &pool, gone, admin, 0).await;
    let thread = s.open_thread(gone, fresh).await.unwrap().channel.id;
    let reply = post(&s, &pool, thread, admin, 0).await;
    s.delete_channel(gone).await.unwrap();

    let swept = s.sweep_message_retention().await.unwrap();

    assert!(
        !is_live(&s, fresh).await,
        "no window is needed once the channel is gone"
    );
    assert!(!is_live(&s, reply).await, "nor for its threads");
    assert_eq!(swept.pruned.len(), 2);
}

#[tokio::test]
async fn one_tick_clears_more_than_one_batch() {
    let (s, pool, _guard) = harness("slimm-chan-retention-backlog").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    for _ in 0..450 {
        post(&s, &pool, channel, admin, 40).await;
    }
    s.set_message_retention_days(30).await.unwrap();

    let swept = s.sweep_message_retention().await.unwrap();

    assert_eq!(
        swept.pruned.len(),
        450,
        "not 200 now and the rest six hours later"
    );
}

#[tokio::test]
async fn the_space_preview_leaves_out_channels_with_their_own_window() {
    let (s, pool, _guard) = harness("slimm-chan-retention-space-preview").await;
    let admin = register(&s, "root").await;
    let own = general(&s).await;
    let other = s.create_channel("other", "text").await.unwrap().id;
    post(&s, &pool, own, admin, 40).await;
    post(&s, &pool, other, admin, 40).await;
    s.set_channel_retention_days(own, Some(0)).await.unwrap();

    assert_eq!(s.count_messages_past_retention(30).await.unwrap(), 1);
}

#[tokio::test]
async fn the_routes_round_trip_preview_and_clear() {
    let (s, pool, _guard) = harness("slimm-chan-retention-http").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    post(&s, &pool, channel, admin, 40).await;
    post(&s, &pool, channel, admin, 5).await;
    let session = s.open_session(admin, "phone").await.unwrap();
    let router = app(s);
    let base = format!("/channels/{}/retention", channel.0);

    let read = router
        .clone()
        .oneshot(request("GET", &base, &session.access_token, None))
        .await
        .unwrap();
    assert_eq!(read.status(), StatusCode::OK);
    assert_eq!(
        json_body(read).await,
        json!({"retention_days": null, "space_retention_days": 0})
    );

    let preview = router
        .clone()
        .oneshot(request(
            "GET",
            &format!("{base}/preview?days=30"),
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(preview).await,
        json!({"retention_days": 30, "messages": 1})
    );

    let set = router
        .clone()
        .oneshot(request(
            "PUT",
            &base,
            &session.access_token,
            Some(json!({"retention_days": 30})),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(set).await["retention_days"], json!(30));

    let cleared = router
        .clone()
        .oneshot(request(
            "PUT",
            &base,
            &session.access_token,
            Some(json!({"retention_days": null})),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(cleared).await["retention_days"], Value::Null);
}

#[tokio::test]
async fn the_routes_need_manage_server_and_refuse_threads() {
    let (s, pool, _guard) = harness("slimm-chan-retention-guard").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let parent = post(&s, &pool, channel, admin, 0).await;
    let thread = s.open_thread(channel, parent).await.unwrap().channel.id;
    let member = s.create_user("nia", "Nia").await.unwrap();
    let member_session = s.open_session(member.id, "phone").await.unwrap();
    let admin_session = s.open_session(admin, "phone").await.unwrap();
    let router = app(s);

    let forbidden = router
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/retention", channel.0),
            &member_session.access_token,
            Some(json!({"retention_days": 0})),
        ))
        .await
        .unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);

    let on_thread = router
        .oneshot(request(
            "GET",
            &format!("/channels/{}/retention", thread.0),
            &admin_session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(on_thread.status(), StatusCode::BAD_REQUEST);
}
