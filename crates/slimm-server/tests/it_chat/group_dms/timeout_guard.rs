// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A timeout reaches the routes that start or end conversations: opening a DM, making a group,
//! adding to one and deleting one, while leaving and hiding stay open.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;

use crate::group_dms::rig::*;

async fn time_out(h: &Harness, who: &Person, by: &Person) {
    let until = crate::support::totp_clock::now_ms() + 3_600_000;
    let (who, by) = (
        UserId(who.id.parse().unwrap()),
        UserId(by.id.parse().unwrap()),
    );
    h.store
        .set_member_timeout(who, until, Some("cool off"), by)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_timed_out_member_cannot_open_a_dm_or_make_a_group() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    time_out(&h, &a, &admin).await;

    let (status, body) = call(&h, "POST", &format!("/dms/{}", b.id), &a, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "timed_out");
    assert!(list(&h, &b).await.is_empty(), "no conversation reached bob");

    let (status, body) = create(&h, &a, &[&b, &c]).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "timed_out");
    assert!(list(&h, &b).await.is_empty());
}

#[tokio::test]
async fn a_timed_out_member_cannot_add_to_or_delete_a_group_but_can_leave_it() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c, d) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    time_out(&h, &a, &admin).await;

    let members = format!("/dms/groups/{channel}/members");
    let (status, body) = call(&h, "POST", &members, &a, Some(json!({ "user_id": d.id }))).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "timed_out");
    let (status, body) = call(&h, "DELETE", &format!("/dms/groups/{channel}"), &a, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "timed_out");
    assert_eq!(list(&h, &b).await.len(), 1, "the group is still there");

    let (status, _) = call(
        &h,
        "POST",
        &format!("/dms/groups/{channel}/leave"),
        &a,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}
