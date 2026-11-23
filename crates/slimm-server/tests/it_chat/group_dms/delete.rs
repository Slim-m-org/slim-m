// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Deleting a group for everyone: equal powers, nothing left behind, nobody else told.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::store::NewMessage;

use crate::group_dms::rig::*;
use crate::support::ws::{Client, connect, read_frame, serve};

async fn delete(h: &Harness, channel: &str, who: &Person) -> StatusCode {
    call(h, "DELETE", &format!("/dms/groups/{channel}"), who, None)
        .await
        .0
}

async fn search(h: &Harness, who: &Person, channel: &str, text: &str) -> (StatusCode, Vec<Value>) {
    let uri = format!("/channels/{channel}/messages/search?q={text}");
    let (status, body) = call(h, "GET", &uri, who, None).await;
    (status, body.as_array().cloned().unwrap_or_default())
}

async fn socket(h: &Harness, addr: std::net::SocketAddr, who: &Person) -> Client {
    let ctx = h.store.authenticate(&who.token).await.unwrap().unwrap();
    let (ticket, _) = h.store.mint_ws_ticket(&ctx).await.unwrap();
    connect(addr, &ticket).await
}

async fn heard_deleted_until_sentinel(ws: &mut Client) -> Vec<String> {
    let mut heard = Vec::new();
    let drain = async {
        loop {
            let frame: Value = read_frame(ws).await;
            match frame["type"].as_str() {
                Some("channel.deleted") => {
                    heard.push(frame["channel_id"].as_str().unwrap().to_owned())
                }
                Some("space.settings_changed") => return,
                _ => {}
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), drain)
        .await
        .expect("the sentinel frame never arrived");
    heard
}

#[tokio::test]
async fn a_member_who_did_not_create_the_group_can_rename_and_delete_it() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;

    let uri = format!("/dms/groups/{channel}");
    let (status, _) = call(&h, "PATCH", &uri, &c, Some(json!({ "name": "ours" }))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(delete(&h, &channel, &c).await, StatusCode::NO_CONTENT);

    for who in [&a, &b, &c] {
        assert!(list(&h, who).await.is_empty());
        assert_ne!(read(&h, &channel, who).await, StatusCode::OK);
    }
}

#[tokio::test]
async fn a_non_member_learns_nothing_and_changes_nothing() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c, outsider) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let never_made = Uuid_v7();

    for who in [&outsider, &admin] {
        let real = delete(&h, &channel, who).await;
        let absent = delete(&h, &never_made, who).await;
        assert_eq!(real, StatusCode::NOT_FOUND);
        assert_eq!(
            real, absent,
            "a real group answers like one that is not there"
        );
        let (status, _) = call(
            &h,
            "PATCH",
            &format!("/dms/groups/{channel}"),
            who,
            Some(json!({ "name": "mine" })),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
    assert_eq!(list(&h, &a).await.len(), 1);
    assert_eq!(read(&h, &channel, &b).await, StatusCode::OK);
}

#[allow(non_snake_case)]
fn Uuid_v7() -> String {
    uuid::Uuid::now_v7().to_string()
}

#[tokio::test]
async fn deleting_removes_history_search_and_attachments_for_everyone() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let channel_id = ChannelId(channel.parse().unwrap());
    let sha256 = vec![9u8; 32];
    h.store
        .store_attachment(
            &sha256,
            1_000,
            "image/png",
            "a.png",
            Some(UserId(a.id.parse().unwrap())),
        )
        .await
        .unwrap();
    let message = h
        .store
        .send_message(NewMessage {
            channel_id,
            author_id: UserId(a.id.parse().unwrap()),
            id: MessageId::generate(),
            content: "zebrafinch",
            attachment_ids: std::slice::from_ref(&sha256),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .unwrap()
        .message;
    assert_eq!(search(&h, &b, &channel, "zebrafinch").await.1.len(), 1);

    assert_eq!(delete(&h, &channel, &b).await, StatusCode::NO_CONTENT);

    for who in [&a, &b, &c] {
        assert!(search(&h, who, &channel, "zebrafinch").await.1.is_empty());
        assert_ne!(read(&h, &channel, who).await, StatusCode::OK);
        assert!(list(&h, who).await.is_empty());
    }
    // The route prunes in the background, so the sweep a moment later has nothing left to do.
    let freed = async {
        while h.store.attachment_summary(&sha256).await.unwrap().is_some() {
            h.store.sweep_message_retention().await.unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(5), freed)
        .await
        .expect("the attachment was never freed");
    let leftover = h.store.list_messages(channel_id, None, 10).await.unwrap();
    assert!(leftover.iter().all(|m| m.id != message.id));
}

#[tokio::test]
async fn deleting_twice_is_harmless_and_the_fan_out_reaches_members_only() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c, outsider) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    let addr = serve(h.state.clone()).await;
    let mut alice = socket(&h, addr, &a).await;
    let mut bob = socket(&h, addr, &b).await;
    let mut dave = socket(&h, addr, &outsider).await;
    let mut root = socket(&h, addr, &admin).await;

    assert_eq!(delete(&h, &channel, &a).await, StatusCode::NO_CONTENT);
    assert_eq!(delete(&h, &channel, &a).await, StatusCode::NO_CONTENT);
    assert_eq!(delete(&h, &channel, &b).await, StatusCode::NO_CONTENT);

    h.hub
        .publish(slimm_server::hub::Event::SpaceSettingsChanged);
    for (who, ws) in [("alice", &mut alice), ("bob", &mut bob)] {
        let heard = heard_deleted_until_sentinel(ws).await;
        assert_eq!(heard, vec![channel.clone()], "{who} hears it once");
    }
    for (who, ws) in [("an outsider", &mut dave), ("an administrator", &mut root)] {
        let heard = heard_deleted_until_sentinel(ws).await;
        assert!(heard.is_empty(), "{who} heard {heard:?}");
    }
}
