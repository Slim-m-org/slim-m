// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a pair DM does once the other person is no longer in the Space.
//!
//! The client reads the roster and says so; these pin the server facts it relies on.

use axum::http::StatusCode;
use slimm_server::ids::UserId;

use crate::group_dms::rig::*;

async fn open(h: &Harness, by: &Person, with: &Person) -> String {
    let (status, body) = call(h, "POST", &format!("/dms/{}", with.id), by, None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["channel_id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_removed_peer_stays_listed_and_a_send_is_accepted_but_unread() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b) = (person(&h, "alice").await, person(&h, "bob").await);
    let channel = open(&h, &a, &b).await;
    h.store
        .remove_from_space(
            UserId(b.id.parse().unwrap()),
            UserId(admin.id.parse().unwrap()),
            None,
        )
        .await
        .unwrap();

    assert_eq!(list(&h, &a).await.len(), 1, "the row stays");
    assert_eq!(send(&h, &channel, &a, "still there?").await, StatusCode::OK);
    let (_, members) = call(&h, "GET", "/members", &a, None).await;
    assert!(
        members
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["id"] != b.id.as_str()),
        "the roster is what tells a client they have gone"
    );
}

#[tokio::test]
async fn a_deleted_peer_drops_off_the_list_but_an_open_channel_still_takes_a_send() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b) = (person(&h, "alice").await, person(&h, "bob").await);
    let channel = open(&h, &a, &b).await;
    h.store
        .delete_account(UserId(b.id.parse().unwrap()))
        .await
        .unwrap();

    assert!(list(&h, &a).await.is_empty());
    assert_eq!(send(&h, &channel, &a, "hello?").await, StatusCode::OK);
}
