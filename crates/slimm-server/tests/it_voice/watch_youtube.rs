// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A watch party of a YouTube video: the bot names the provider and every
//! viewer plays the id in YouTube's own embed. See
//! docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.

use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::support;
use support::watch_world::{call, film, session_uri, world};

fn clip(id: &str) -> Value {
    json!({
        "provider": "youtube",
        "item_id": id,
        "title": "A Clip",
        "duration_ms": 212_000,
        "playing": true,
        "position_ms": 0,
    })
}

#[tokio::test]
async fn a_member_reads_the_provider_the_bot_named_and_an_older_bot_reads_as_jellyfin() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let (set, _) = call(&w, "PUT", &uri, &w.bot, Some(clip("dQw4w9WgXcQ"))).await;
    assert_eq!(set, StatusCode::NO_CONTENT);
    let (_, body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(body["provider"], "youtube");
    assert_eq!(body["item_id"], "dQw4w9WgXcQ");

    call(&w, "PUT", &uri, &w.bot, Some(film(0, true))).await;
    let (_, film_body) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(film_body["provider"], "jellyfin");
}

#[tokio::test]
async fn switching_provider_on_the_same_id_moves_the_epoch() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let mut first = film(0, true);
    first["item_id"] = json!("abcdefghijk");
    call(&w, "PUT", &uri, &w.bot, Some(first)).await;
    let (_, before) = call(&w, "GET", &uri, &w.member, None).await;
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    call(&w, "PUT", &uri, &w.bot, Some(clip("abcdefghijk"))).await;
    let (_, after) = call(&w, "GET", &uri, &w.member, None).await;
    assert!(after["epoch"].as_i64() > before["epoch"].as_i64());
}

#[tokio::test]
async fn an_unknown_provider_a_malformed_id_or_a_direct_play_offer_is_refused() {
    let w = world().await;
    let uri = session_uri(w.voice);
    let mut unknown = clip("dQw4w9WgXcQ");
    unknown["provider"] = json!("vimeo");
    let mut offered = clip("dQw4w9WgXcQ");
    offered["direct_play"] = json!({"base_url": "https://example.com"});
    for bad in [
        unknown,
        clip("../etc/passwd"),
        clip(&"a".repeat(33)),
        offered,
    ] {
        let (status, _) = call(&w, "PUT", &uri, &w.bot, Some(bad)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    // Four writes is the bot's whole burst, so each refusal above was the validator's.
    let (none, _) = call(&w, "GET", &uri, &w.member, None).await;
    assert_eq!(none, StatusCode::NOT_FOUND);
}
