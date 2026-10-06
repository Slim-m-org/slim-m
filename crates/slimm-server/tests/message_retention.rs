// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Message retention: the config round trip, what one sweep tick prunes and
//! frees, and the floor/reset mechanism a client offline across a prune
//! recovers through. See `store/message_retention.rs`'s own doc for the
//! mechanism, and `sync_message_ops.rs` for the pre-existing op-gap tests
//! this shares its route with.

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
use slimm_server::store::{MAX_MESSAGE_RETENTION_DAYS, NewMessage, Store};
use slimm_server::voice::VoiceService;
use sqlx::SqlitePool;
use tower::ServiceExt;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

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

/// Rewrites a `message_ops` row's own `created_at`, simulating an op minted
/// long enough ago that the op-log reclaim pass should now consider it stale.
async fn backdate_op(pool: &SqlitePool, channel_id: ChannelId, seq: i64, created_at: i64) {
    sqlx::query("UPDATE message_ops SET created_at = ? WHERE channel_id = ? AND seq = ?")
        .bind(created_at)
        .bind(channel_id)
        .bind(seq)
        .execute(pool)
        .await
        .unwrap();
}

#[tokio::test]
async fn retention_is_off_by_default() {
    let (s, _pool, _guard) = harness("slimm-retention-default").await;
    assert_eq!(s.message_retention_days().await.unwrap(), 0);
}

#[tokio::test]
async fn the_window_round_trips_over_http() {
    let (s, _pool, _guard) = harness("slimm-retention-roundtrip").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);

    let response = router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/retention",
            &session.access_token,
            Some(json!({"retention_days": 30})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await["retention_days"], json!(30));

    let response = router
        .oneshot(request(
            "GET",
            "/space/retention",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(json_body(response).await["retention_days"], json!(30));
}

#[tokio::test]
async fn updating_retention_requires_manage_server() {
    let (s, _pool, _guard) = harness("slimm-retention-forbidden").await;
    let admin = register(&s, "root").await;
    let member = s.create_user("nia", "Nia").await.unwrap();
    let session = s.open_session(member.id, "phone").await.unwrap();
    let _ = admin;
    let router = app(s);

    let response = router
        .oneshot(request(
            "PATCH",
            "/space/retention",
            &session.access_token,
            Some(json!({"retention_days": 30})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn an_out_of_range_window_is_refused() {
    let (s, _pool, _guard) = harness("slimm-retention-range").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);

    for bad in [-1, MAX_MESSAGE_RETENTION_DAYS + 1] {
        let response = router
            .clone()
            .oneshot(request(
                "PATCH",
                "/space/retention",
                &session.access_token,
                Some(json!({"retention_days": bad})),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "days={bad}");
    }
}

#[tokio::test]
async fn a_disabled_window_sweeps_nothing() {
    let (s, pool, _guard) = harness("slimm-retention-off-sweep").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    let id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "old",
        ))
        .await
        .unwrap()
        .message
        .id;
    backdate_message(&pool, id, -365 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();
    assert!(swept.pruned.is_empty());
    assert_eq!(swept.ops_reclaimed, 0);
    assert_eq!(s.list_messages(channel, None, 10).await.unwrap().len(), 1);
}

/// The content half: a message older than the window is pruned exactly the
/// way a manual delete already prunes one, and its only attachment is freed.
#[tokio::test]
async fn the_sweep_prunes_an_old_message_and_frees_its_only_attachment() {
    let (s, pool, _guard) = harness("slimm-retention-sweep").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let sha256 = vec![7u8; 32];
    s.store_attachment(&sha256, 1_000, "image/png", "a.png", Some(admin))
        .await
        .unwrap();
    let old_id = s
        .send_message(NewMessage {
            channel_id: channel,
            author_id: admin,
            id: MessageId::generate(),
            content: "old",
            attachment_ids: std::slice::from_ref(&sha256),
            reply_to_id: None,
            forward: None,
        })
        .await
        .unwrap()
        .message
        .id;
    backdate_message(&pool, old_id, -60 * DAY_MS).await;

    let recent_id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "recent",
        ))
        .await
        .unwrap()
        .message
        .id;

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 1);
    let pruned = &swept.pruned[0];
    assert_eq!(pruned.message_id, old_id);
    assert_eq!(pruned.channel_id, channel);
    assert!(pruned.op_seq.is_some());
    assert_eq!(
        pruned.freed_attachments,
        vec![slimm_server::media::to_hex(&sha256)]
    );

    let live = s.list_messages(channel, None, 10).await.unwrap();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].id, recent_id);
    assert!(s.attachment_summary(&sha256).await.unwrap().is_none());

    let ops = s.message_ops_since(channel, 0, 10).await.unwrap();
    assert_eq!(ops.ops.len(), 1);
    assert_eq!(ops.ops[0].message_id, old_id);
}

/// The op-log half: an op old enough to predate the same cutoff is reclaimed,
/// which is the mechanism a stranded offline client's reset rides on.
#[tokio::test]
async fn the_sweep_reclaims_message_ops_older_than_the_same_cutoff() {
    let (s, pool, _guard) = harness("slimm-retention-op-reclaim").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "one",
        ))
        .await
        .unwrap()
        .message
        .id;
    s.edit_message(id, "revised", admin).await.unwrap();
    backdate_op(&pool, channel, 1, -60 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.ops_reclaimed, 1);
    assert!(swept.pruned.is_empty());

    let ops = s.message_ops_since(channel, 0, 10).await.unwrap();
    assert!(ops.ops.is_empty(), "the reclaimed op must not still page");
    assert_eq!(ops.latest_seq, 1, "the counter itself never rewinds");
}

/// The cutoff is a real filter, not a rubber stamp: an op inside the window
/// survives a sweep tick untouched.
#[tokio::test]
async fn the_sweep_never_reclaims_an_op_within_the_window() {
    let (s, _pool, _guard) = harness("slimm-retention-op-keep").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "one",
        ))
        .await
        .unwrap()
        .message
        .id;
    s.edit_message(id, "revised", admin).await.unwrap();

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.ops_reclaimed, 0);
    let ops = s.message_ops_since(channel, 0, 10).await.unwrap();
    assert_eq!(ops.ops.len(), 1);
}

/// A message pruned this tick writes a delete op stamped `now`, and the same
/// tick's op-log reclaim (bounded by `cutoff`, a whole retention window
/// behind `now`) must not be the thing that deletes it.
#[tokio::test]
async fn a_freshly_written_prune_delete_op_survives_the_same_ticks_op_log_reclaim() {
    let (s, pool, _guard) = harness("slimm-retention-fresh-op-survives").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(1).await.unwrap();

    let old_id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "old",
        ))
        .await
        .unwrap()
        .message
        .id;
    backdate_message(&pool, old_id, -60 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.pruned.len(), 1);
    let ops = s.message_ops_since(channel, 0, 10).await.unwrap();
    assert_eq!(
        ops.ops.len(),
        1,
        "the prune's own delete op must still be there"
    );
    assert_eq!(ops.ops[0].message_id, old_id);
}

/// The acceptance case: a client offline since before a now-reclaimed op
/// cannot be caught up incrementally, so it must be told to reset rather than
/// silently served an empty, un-caught-up page - and a client that was
/// already current when the reclaim ran must not be reset for no reason.
#[tokio::test]
async fn an_offline_client_recovers_via_reset_once_its_cursor_falls_behind_the_reclaimed_floor() {
    let (s, pool, _guard) = harness("slimm-retention-reset").await;
    let admin = register(&s, "root").await;
    let channel = general(&s).await;
    s.set_message_retention_days(30).await.unwrap();

    let id = s
        .send_message(NewMessage::plain(
            channel,
            admin,
            MessageId::generate(),
            "one",
        ))
        .await
        .unwrap()
        .message
        .id;
    s.delete_message(id, admin).await.unwrap();
    backdate_op(&pool, channel, 1, -90 * DAY_MS).await;

    let swept = s.sweep_message_retention().await.unwrap();
    assert_eq!(swept.ops_reclaimed, 1);

    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);

    let behind = router
        .clone()
        .oneshot(request(
            "POST",
            "/sync",
            &session.access_token,
            Some(json!({
                "scopes": [{
                    "channel_id": channel.to_string(),
                    "after_seq": 0,
                    "after_op_seq": 0,
                }]
            })),
        ))
        .await
        .unwrap();
    let behind_body = json_body(behind).await;
    assert_eq!(
        behind_body["scopes"][0]["reset"],
        json!(true),
        "{behind_body}"
    );

    let caught_up = router
        .oneshot(request(
            "POST",
            "/sync",
            &session.access_token,
            Some(json!({
                "scopes": [{
                    "channel_id": channel.to_string(),
                    "after_seq": 1,
                    "after_op_seq": 1,
                }]
            })),
        ))
        .await
        .unwrap();
    let caught_up_body = json_body(caught_up).await;
    assert_eq!(
        caught_up_body["scopes"][0]["reset"],
        json!(false),
        "{caught_up_body}"
    );
}
