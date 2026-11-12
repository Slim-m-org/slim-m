// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A watch session is tied to the bot's place on the call: who may write it,
//! when it reads as ended, and what a viewer is told. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Event;
use slimm_server::ids::UserId;

use crate::support;
use support::watch_world::{World, call, film, session_uri, world};

fn leave_call(w: &World, bot: UserId) {
    assert!(
        w.state
            .voice
            .forget_heartbeat_reporting_removed(bot, w.voice)
    );
}

fn epoch(body: &Value) -> i64 {
    body["epoch"].as_i64().unwrap()
}

#[tokio::test]
async fn a_bot_off_the_call_can_neither_set_nor_tick_a_session() {
    let w = world().await;
    let uri = session_uri(w.voice);
    leave_call(&w, w.bot_id);
    let (set, _) = call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    assert_eq!(set, StatusCode::FORBIDDEN);

    call(&w, "PUT", &uri, &w.other_bot, Some(film(0, true))).await;
    leave_call(&w, w.other_bot_id);
    let tick = json!({ "playing": true, "position_ms": 5 });
    let (status, _) = call(&w, "POST", &format!("{uri}/tick"), &w.other_bot, Some(tick)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_session_whose_bot_left_the_call_reads_as_ended_and_can_be_taken() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    leave_call(&w, w.bot_id);

    let (read, _) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(read, StatusCode::NOT_FOUND);
    let (taken, _) = call(&w, "PUT", &uri, &w.other_bot, Some(film(0, true))).await;
    assert_eq!(taken, StatusCode::NO_CONTENT);
    let (_, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(body["bot_user_id"], w.other_bot_id.to_string());
}

#[tokio::test]
async fn ending_a_session_tells_the_viewers() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(9_000, true))).await;
    let mut ephemeral = w.state.hub.subscribe_ephemeral();
    let (status, _) = call(&w, "DELETE", &uri, &w.bot, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    match ephemeral.try_recv().unwrap() {
        Event::WatchTick {
            bot_user_id, ended, ..
        } => {
            assert!(ended);
            assert_eq!(bot_user_id, w.bot_id);
        }
        other => panic!("expected an ended tick, got {other:?}"),
    }
}

#[tokio::test]
async fn hanging_up_the_bots_call_ends_its_session_and_says_so() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let mut ephemeral = w.state.hub.subscribe_ephemeral();
    let hangup = format!("/channels/{}/voice/heartbeat", w.voice);
    let (status, _) = call(&w, "DELETE", &hangup, &w.bot, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(matches!(
        ephemeral.try_recv().unwrap(),
        Event::WatchTick { ended: true, .. }
    ));
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM watch_sessions")
        .fetch_one(&w.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn the_epoch_never_repeats_across_an_end_and_a_fresh_session() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (_, first) = call(&w, "GET", &uri, &w.member, None).await;
    call(&w, "DELETE", &uri, &w.bot, None).await;
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (_, second) = call(&w, "GET", &uri, &w.member, None).await;
    assert!(epoch(&second) > epoch(&first));
}

#[tokio::test]
async fn the_controller_must_be_someone_who_can_view_the_channel() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let mut body = film(0, true);
    body["controller_user_id"] = json!(UserId::generate().to_string());
    let (stranger, _) = call(&w, "PUT", &uri, &w.bot, Some(body)).await;
    assert_eq!(stranger, StatusCode::BAD_REQUEST);

    let mut body = film(0, true);
    body["controller_user_id"] = json!(w.alice.to_string());
    let (member, _) = call(&w, "PUT", &uri, &w.bot, Some(body)).await;
    assert_eq!(member, StatusCode::NO_CONTENT);
    let (_, read) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(read["controller_user_id"], w.alice.to_string());
}

#[tokio::test]
async fn a_deleted_controller_is_forgotten() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let mut body = film(0, true);
    body["controller_user_id"] = json!(w.alice.to_string());
    call(&w, "PUT", &uri, &w.bot, Some(body)).await;
    w.state.store.delete_account(w.alice).await.unwrap();
    let (_, read) = call(&w, "GET", &uri, &w.bot, None).await;
    assert_eq!(read["controller_user_id"], Value::Null);
}

#[tokio::test]
async fn setting_a_session_is_rate_limited_like_a_tick() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let mut last = StatusCode::NO_CONTENT;
    for _ in 0..12 {
        (last, _) = call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    }
    assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_bot_back_after_the_session_lapsed_starts_a_new_epoch() {
    let w = world().await;
    let uri = session_uri(w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (_, before) = call(&w, "GET", &uri, &w.member, None).await;
    let stale = slimm_server::store::WATCH_SESSION_TTL_MS + 1_000;
    sqlx::query("UPDATE watch_sessions SET sampled_at = sampled_at - ?")
        .bind(stale)
        .execute(&w.pool)
        .await
        .unwrap();
    call(&w, "PUT", &uri, &w.bot, Some(film(900_000, true))).await;
    let (_, after) = call(&w, "GET", &uri, &w.member, None).await;
    assert!(epoch(&after) > epoch(&before));
}
