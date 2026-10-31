// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a watch party offers a viewer who plays the title themselves, and the
//! report that tells the bot when nobody needs its shared stream. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use axum::http::StatusCode;
use serde_json::{Value, json};

mod support;

use support::watch_world::{call, film, session_uri, world};

fn offering(verified: &[String]) -> Value {
    let mut body = film(1_000, true);
    body["direct_play"] = json!({
        "base_url": "http://10.0.0.5:8096",
        "verified_user_ids": verified,
        "unverified_user_ids": [],
    });
    body
}

#[tokio::test]
async fn the_offer_the_bot_states_is_what_a_member_reads_and_a_restated_session_without_one_drops_it()
 {
    let w = world().await;
    let uri = session_uri(w.voice);
    let me = w.alice.to_string();
    let (set, _) = call(
        &w,
        "PUT",
        &uri,
        &w.bot,
        Some(offering(std::slice::from_ref(&me))),
    )
    .await;
    assert_eq!(set, StatusCode::NO_CONTENT);

    let (_, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(body["direct_play"]["base_url"], "http://10.0.0.5:8096");
    assert_eq!(body["direct_play"]["verified_user_ids"], json!([me]));
    assert_eq!(body["direct_viewer_ids"], json!([]));

    call(&w, "PUT", &uri, &w.bot, Some(film(2_000, true))).await;
    let (_, bare) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(bare["direct_play"], Value::Null);
}

#[tokio::test]
async fn a_hostile_offer_is_refused() {
    let w = world().await;
    let uri = session_uri(w.voice);
    for bad in [
        json!({"base_url": "javascript:alert(1)"}),
        json!({"base_url": "http://a b"}),
        json!({"base_url": "http://ok", "verified_user_ids": ["not-a-uuid"]}),
    ] {
        let mut body = film(0, true);
        body["direct_play"] = bad;
        let (status, _) = call(&w, "PUT", &uri, &w.bot, Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

#[tokio::test]
async fn a_viewer_on_the_call_is_listed_until_they_retract_and_nobody_else_can_report() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let viewing = format!("{uri}/viewing");
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;

    let (off_call, _) = call(
        &w,
        "PUT",
        &viewing,
        &w.member,
        Some(json!({"direct": true})),
    )
    .await;
    assert_eq!(off_call, StatusCode::FORBIDDEN);

    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice, w.voice);
    let (ok, _) = call(
        &w,
        "PUT",
        &viewing,
        &w.member,
        Some(json!({"direct": true})),
    )
    .await;
    assert_eq!(ok, StatusCode::NO_CONTENT);
    let (_, body) = call(&w, "GET", &uri, &w.bot, None).await;
    assert_eq!(body["direct_viewer_ids"], json!([w.alice.to_string()]));

    let (bot, _) = call(&w, "PUT", &viewing, &w.bot, Some(json!({"direct": true}))).await;
    assert_eq!(bot, StatusCode::FORBIDDEN);

    call(
        &w,
        "PUT",
        &viewing,
        &w.member,
        Some(json!({"direct": false})),
    )
    .await;
    let (_, after) = call(&w, "GET", &uri, &w.bot, None).await;
    assert_eq!(after["direct_viewer_ids"], json!([]));
}

#[tokio::test]
async fn ending_the_session_forgets_who_was_direct() {
    let w = world().await;
    let uri = session_uri(w.voice);
    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice, w.voice);
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    call(
        &w,
        "PUT",
        &format!("{uri}/viewing"),
        &w.member,
        Some(json!({"direct": true})),
    )
    .await;
    call(&w, "DELETE", &uri, &w.bot, None).await;
    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (_, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(body["direct_viewer_ids"], json!([]));
}
