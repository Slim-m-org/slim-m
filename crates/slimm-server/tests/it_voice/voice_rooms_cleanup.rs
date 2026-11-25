// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing an emptied temporary voice room, and keeping it while a join is in flight.

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

use super::voice_rooms::{signed_webhook, world};
use crate::support;

#[tokio::test]
async fn an_empty_room_is_removed_and_a_busy_one_or_a_plain_channel_is_not() {
    let w = world("slimm-rooms-cleanup").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();

    w.present.lock().unwrap().push(w.bob.1.clone());
    w.remove_if_empty(&id).await;
    assert!(w.listed(&w.alice.0, &id).await, "someone is still in it");

    w.present.lock().unwrap().clear();
    w.remove_if_empty(&w.lobby).await;
    assert!(
        w.listed(&w.alice.0, &w.lobby).await,
        "a lobby is never removed"
    );
    w.remove_if_empty(&id).await;
    assert!(!w.listed(&w.alice.0, &id).await, "the empty room is gone");

    let again = w.open_room(&w.alice.0).await;
    assert_ne!(
        again["id"],
        json!(id),
        "a fresh room after the old one went"
    );
}

#[tokio::test]
async fn an_empty_room_with_a_join_in_flight_is_kept_until_the_grace_passes() {
    let w = world("slimm-rooms-pending-join").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();

    assert_eq!(w.token_status(&w.bob.0, &id).await, StatusCode::OK);
    w.remove_if_empty(&id).await;
    assert!(
        w.listed(&w.alice.0, &id).await,
        "a member who just got a token is still joining"
    );
}

#[tokio::test]
async fn the_last_person_leaving_removes_the_room_through_the_webhook() {
    let w = world("slimm-rooms-webhook").await;
    let room = w.open_room(&w.alice.0).await;
    let id = room["id"].as_str().unwrap().to_owned();
    let left = json!({
        "event": "participant_left",
        "room": { "name": format!("channel-{id}") },
        "participant": { "identity": w.alice.1 },
    });
    let status = w
        .app
        .clone()
        .oneshot(signed_webhook(&left))
        .await
        .unwrap()
        .status();
    assert_eq!(status, StatusCode::NO_CONTENT);
    support::wait::wait_until_async("the emptied room to leave the list", || async {
        !w.listed(&w.alice.0, &id).await
    })
    .await;
}
