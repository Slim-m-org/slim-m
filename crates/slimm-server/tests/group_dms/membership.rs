// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who can reach a group, how big it gets, and how blocks gate it.

use axum::http::StatusCode;
use serde_json::json;

use crate::rig::*;

#[tokio::test]
async fn every_participant_sees_the_group_and_can_talk_in_it() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;

    for who in [&a, &b, &c] {
        let rows = list(&h, who).await;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["channel_id"], channel);
        let mut ids = member_ids(&rows[0]["group"]);
        ids.sort();
        let mut want = vec![a.id.clone(), b.id.clone(), c.id.clone()];
        want.sort();
        assert_eq!(ids, want);
        assert!(rows[0]["group"]["name"].is_null());
        assert_eq!(send(&h, &channel, who, "hi").await, StatusCode::OK);
        assert_eq!(read(&h, &channel, who).await, StatusCode::OK);
    }
}

#[tokio::test]
async fn an_outsider_and_an_administrator_cannot_reach_a_group() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;

    for outsider in [&d, &admin] {
        assert_eq!(read(&h, &channel, outsider).await, StatusCode::FORBIDDEN);
        assert_eq!(
            send(&h, &channel, outsider, "hi").await,
            StatusCode::FORBIDDEN
        );
        assert!(list(&h, outsider).await.is_empty());
    }
}

#[tokio::test]
async fn a_pair_dm_is_untouched_and_carries_no_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b) = (person(&h, "alice").await, person(&h, "bob").await);
    let (status, opened) = call(&h, "POST", &format!("/dms/{}", b.id), &a, None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(opened.get("group").is_none());
    let rows = list(&h, &a).await;
    assert_eq!(rows.len(), 1);
    assert!(rows[0].get("group").is_none());
}

#[tokio::test]
async fn a_group_has_three_to_eight_people_counting_the_creator() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let creator = person(&h, "creator").await;
    let mut others = Vec::new();
    for n in 0..8 {
        others.push(person(&h, &format!("user{n}")).await);
    }
    let refs: Vec<&Person> = others.iter().collect();

    assert_eq!(
        create(&h, &creator, &refs[..1]).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(create(&h, &creator, &[]).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(create(&h, &creator, &refs).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(
        create(&h, &creator, &refs[..2]).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        create(&h, &creator, &refs[..7]).await.0,
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn naming_yourself_or_repeating_someone_does_not_pad_the_count() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b) = (person(&h, "alice").await, person(&h, "bob").await);
    assert_eq!(
        create(&h, &a, &[&a, &b, &b]).await.0,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn a_block_between_any_two_people_refuses_the_group_and_says_why() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    // Two invitees who blocked each other, the creator blocked by neither.
    block(&h, &b, &c).await;
    let (status, body) = create(&h, &a, &[&b, &c]).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let message = body["error"].as_str().or(body["message"].as_str());
    assert!(
        message.is_some_and(|m| m.contains("block")),
        "the refusal must explain itself: {body}"
    );
    assert!(list(&h, &a).await.is_empty());
}

#[tokio::test]
async fn the_creator_blocking_or_being_blocked_refuses_the_group_both_ways() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    block(&h, &a, &b).await;
    assert_eq!(create(&h, &a, &[&b, &c]).await.0, StatusCode::FORBIDDEN);
    assert_eq!(create(&h, &b, &[&a, &c]).await.0, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn adding_someone_blocked_by_or_blocking_a_member_is_refused() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let (blocked_by_member, blocker_of_member, fine) = (
        person(&h, "dave").await,
        person(&h, "erin").await,
        person(&h, "frank").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    block(&h, &c, &blocked_by_member).await;
    block(&h, &blocker_of_member, &b).await;
    let add = |who: &Person| {
        let uri = format!("/dms/groups/{channel}/members");
        let body = json!({ "user_id": who.id });
        (uri, body)
    };

    for refused in [&blocked_by_member, &blocker_of_member] {
        let (uri, body) = add(refused);
        let (status, _) = call(&h, "POST", &uri, &a, Some(body)).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(read(&h, &channel, refused).await, StatusCode::FORBIDDEN);
    }
    let (uri, body) = add(&fine);
    let (status, group) = call(&h, "POST", &uri, &a, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{group}");
    assert_eq!(member_ids(&group["group"]).len(), 4);
    assert_eq!(read(&h, &channel, &fine).await, StatusCode::OK);
}

#[tokio::test]
async fn a_group_holds_eight_and_refuses_a_ninth_or_a_repeat() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let creator = person(&h, "creator").await;
    let mut others = Vec::new();
    for n in 0..8 {
        others.push(person(&h, &format!("user{n}")).await);
    }
    let refs: Vec<&Person> = others.iter().collect();
    let channel = group_of(&h, &creator, &refs[..7]).await;
    let uri = format!("/dms/groups/{channel}/members");

    let (status, _) = call(
        &h,
        "POST",
        &uri,
        &creator,
        Some(json!({ "user_id": others[0].id })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "already in the group");
    let (status, _) = call(
        &h,
        "POST",
        &uri,
        &creator,
        Some(json!({ "user_id": others[7].id })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "the group is full");
}

#[tokio::test]
async fn only_a_participant_can_add_someone() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let (status, _) = call(
        &h,
        "POST",
        &format!("/dms/groups/{channel}/members"),
        &d,
        Some(json!({ "user_id": d.id })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(read(&h, &channel, &d).await, StatusCode::FORBIDDEN);
}
