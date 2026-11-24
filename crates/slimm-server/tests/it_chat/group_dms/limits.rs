// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caps and guards around group DMs: how many one account holds, who may name or delete one,
//! and that a retried request lands on the group it already made.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::store::{GROUP_DM_MAX_PER_ACCOUNT, GroupDmError};
use uuid::Uuid;

use crate::group_dms::rig::*;

fn uid(p: &Person) -> UserId {
    UserId(p.id.parse().unwrap())
}

async fn fill_to_cap(h: &Harness, who: &Person, with: [&Person; 2]) {
    for _ in 0..GROUP_DM_MAX_PER_ACCOUNT {
        h.store
            .create_group_dm(uid(who), &[uid(with[0]), uid(with[1])], None, None)
            .await
            .expect("under the cap");
    }
}

#[tokio::test]
async fn creating_past_the_group_cap_is_refused() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    fill_to_cap(&h, &a, [&b, &c]).await;

    let refused = h
        .store
        .create_group_dm(uid(&a), &[uid(&b), uid(&c)], None, None)
        .await;
    assert!(matches!(refused, Err(GroupDmError::TooManyGroups)));
    let (status, _) = create(&h, &a, &[&b, &c]).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn adding_someone_already_at_the_cap_is_refused_and_leaving_frees_a_place() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, full, x, y) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
        person(&h, "erin").await,
        person(&h, "frank").await,
    );
    fill_to_cap(&h, &full, [&x, &y]).await;
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let uri = format!("/dms/groups/{channel}/members");

    let (status, _) = call(&h, "POST", &uri, &a, Some(json!({ "user_id": full.id }))).await;
    assert_eq!(status, StatusCode::CONFLICT);

    let one = list(&h, &full).await[0]["channel_id"]
        .as_str()
        .unwrap()
        .to_owned();
    call(&h, "POST", &format!("/dms/groups/{one}/leave"), &full, None).await;
    let (status, _) = call(&h, "POST", &uri, &a, Some(json!({ "user_id": full.id }))).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn group_creation_has_its_own_budget() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let mut last = StatusCode::CREATED;
    for _ in 0..8 {
        last = create(&h, &a, &[&b, &c]).await.0;
        if last == StatusCode::TOO_MANY_REQUESTS {
            break;
        }
    }
    assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
}

async fn timed_out(h: &Harness, who: &Person, by: &Person) {
    let until = now_ms() + 3_600_000;
    h.store
        .set_member_timeout(uid(who), until, None, uid(by))
        .await
        .unwrap();
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[tokio::test]
async fn a_timed_out_member_cannot_name_or_rename_a_group() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    timed_out(&h, &a, &admin).await;

    let (status, _) = call(
        &h,
        "POST",
        "/dms/groups",
        &a,
        Some(json!({ "id": Uuid::now_v7().to_string(), "user_ids": [b.id, c.id], "name": "hi" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &h,
        "PATCH",
        &format!("/dms/groups/{channel}"),
        &a,
        Some(json!({ "name": "loud" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(list(&h, &b).await[0]["group"]["name"].is_null());
}

#[tokio::test]
async fn a_member_behind_the_join_gate_cannot_rename_or_delete_a_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    sqlx::query("INSERT INTO pending_members (user_id, since) VALUES (?, 0)")
        .bind(uid(&c))
        .execute(&h.pool)
        .await
        .unwrap();

    let uri = format!("/dms/groups/{channel}");
    let (status, _) = call(&h, "PATCH", &uri, &c, Some(json!({ "name": "mine" }))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = call(&h, "DELETE", &uri, &c, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(list(&h, &a).await.len(), 1, "the group is still there");
    assert!(list(&h, &a).await[0]["group"]["name"].is_null());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn racing_creates_with_one_id_land_on_the_same_group() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let id = ChannelId(Uuid::now_v7());
    let (creator, others) = (uid(&a), vec![uid(&b), uid(&c)]);
    let racers: Vec<_> = (0..8)
        .map(|_| {
            let (store, others) = (h.store.clone(), others.clone());
            tokio::spawn(async move {
                store
                    .create_group_dm(creator, &others, None, Some(id))
                    .await
            })
        })
        .collect();
    let mut made = 0;
    for racer in racers {
        let (channel, created) = racer.await.unwrap().expect("every racer succeeds");
        assert_eq!(channel.id, id);
        made += usize::from(created);
    }
    assert_eq!(made, 1, "exactly one of them made it");
}

#[tokio::test]
async fn repeating_an_add_or_a_leave_succeeds() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let add = format!("/dms/groups/{channel}/members");
    for _ in 0..2 {
        let (status, body) = call(&h, "POST", &add, &a, Some(json!({ "user_id": d.id }))).await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }
    let leave = format!("/dms/groups/{channel}/leave");
    for _ in 0..2 {
        let (status, _) = call(&h, "POST", &leave, &d, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
}
