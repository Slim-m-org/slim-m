// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Leaving, renaming, replays, late blocks, events and deleted accounts.

use axum::http::StatusCode;
use serde_json::json;

use slimm_server::hub::Event;
use uuid::Uuid;

use crate::rig::*;

#[tokio::test]
async fn leaving_keeps_the_channel_and_history_for_everyone_else() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    assert_eq!(send(&h, &channel, &b, "before").await, StatusCode::OK);

    let (status, _) = call(
        &h,
        "POST",
        &format!("/dms/groups/{channel}/leave"),
        &b,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert!(list(&h, &b).await.is_empty());
    assert_eq!(read(&h, &channel, &b).await, StatusCode::FORBIDDEN);
    assert_eq!(send(&h, &channel, &b, "after").await, StatusCode::FORBIDDEN);
    for stayer in [&a, &c] {
        assert_eq!(read(&h, &channel, stayer).await, StatusCode::OK);
        let rows = list(&h, stayer).await;
        assert_eq!(member_ids(&rows[0]["group"]).len(), 2);
    }
    assert_eq!(send(&h, &channel, &c, "still here").await, StatusCode::OK);

    let (again, _) = call(
        &h,
        "POST",
        &format!("/dms/groups/{channel}/leave"),
        &b,
        None,
    )
    .await;
    assert_eq!(again, StatusCode::NOT_FOUND, "leaving twice finds nothing");
}

#[tokio::test]
async fn the_last_person_out_deletes_the_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    for who in [&a, &b, &c] {
        let (status, _) = call(
            &h,
            "POST",
            &format!("/dms/groups/{channel}/leave"),
            who,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    for who in [&a, &b, &c] {
        assert!(list(&h, who).await.is_empty());
        assert_ne!(read(&h, &channel, who).await, StatusCode::OK);
    }
    let id = slimm_server::ids::ChannelId(channel.parse().unwrap());
    assert!(
        h.store.channel(id).await.unwrap().is_none(),
        "an empty group is deleted, not left behind with no one in it"
    );
}

#[tokio::test]
async fn any_participant_can_rename_and_clear_the_name() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let uri = format!("/dms/groups/{channel}");

    let (status, body) = call(&h, "PATCH", &uri, &b, Some(json!({ "name": "  trip  " }))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["group"]["name"], "trip");
    assert_eq!(list(&h, &c).await[0]["group"]["name"], "trip");

    let (status, body) = call(&h, "PATCH", &uri, &c, Some(json!({ "name": null }))).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["group"]["name"].is_null());

    let too_long = "x".repeat(65);
    let (status, _) = call(&h, "PATCH", &uri, &a, Some(json!({ "name": too_long }))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = call(&h, "PATCH", &uri, &d, Some(json!({ "name": "mine" }))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn creating_with_a_name_stores_it() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let (status, body) = call(
        &h,
        "POST",
        "/dms/groups",
        &a,
        Some(json!({ "user_ids": [b.id, c.id], "name": "lunch" })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["group"]["name"], "lunch");
}

#[tokio::test]
async fn replaying_a_create_returns_the_same_group_and_a_stranger_cannot_claim_the_id() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let id = Uuid::now_v7().to_string();
    let body = json!({ "id": id, "user_ids": [b.id, c.id] });
    let (first, one) = call(&h, "POST", "/dms/groups", &a, Some(body.clone())).await;
    let (second, two) = call(&h, "POST", "/dms/groups", &a, Some(body.clone())).await;
    assert_eq!(first, StatusCode::CREATED);
    assert_eq!(second, StatusCode::OK);
    assert_eq!(one["channel_id"], two["channel_id"]);
    assert_eq!(list(&h, &a).await.len(), 1);

    let (stolen, _) = call(&h, "POST", "/dms/groups", &d, Some(body)).await;
    assert_eq!(stolen, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_block_made_later_removes_nobody_and_silences_nobody() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    block(&h, &a, &b).await;

    for who in [&a, &b, &c] {
        assert_eq!(
            send(&h, &channel, who, "still talking").await,
            StatusCode::OK
        );
        assert_eq!(list(&h, who).await.len(), 1);
    }
}

#[tokio::test]
async fn the_same_people_can_hold_more_than_one_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let one = group_of(&h, &a, &[&b, &c]).await;
    let two = group_of(&h, &b, &[&a, &c]).await;
    assert_ne!(one, two);
    assert_eq!(list(&h, &c).await.len(), 2);
}

#[tokio::test]
async fn a_group_roster_change_is_announced_to_participants_only() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let mut events = h.hub.subscribe();
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let announced = std::iter::from_fn(|| events.try_recv().ok()).any(|event| {
        matches!(&event, Event::DmChanged { channel_id } if channel_id.to_string() == channel)
    });
    assert!(announced, "creating a group publishes dm.changed");
}

#[tokio::test]
async fn a_deleted_account_drops_out_of_its_groups() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let bob = b.id.parse::<Uuid>().unwrap();
    h.store
        .delete_account(slimm_server::ids::UserId(bob))
        .await
        .expect("delete bob");

    let rows = list(&h, &a).await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["channel_id"], channel);
    assert_eq!(member_ids(&rows[0]["group"]).len(), 2);
}
