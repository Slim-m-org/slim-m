// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space export: an administrator's archive of the community, with no
//! direct messages, deleted content or credentials, written as a stream.

use axum::http::StatusCode;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;

mod support;

use support::app::general_channel_id;
use support::exports::{account, world};

const DM_SECRET: &str = "ALICE-TO-BOB-DM-SECRET";

fn user_id(id: &str) -> UserId {
    UserId(id.parse().unwrap())
}

#[tokio::test]
async fn a_space_export_holds_the_community_and_none_of_the_private_parts() {
    let (store, _guard) = support::new_store("slimm-export-space-contents").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let general = general_channel_id(&store).await;
    w.send(&alice, &general, "hello everyone").await;
    let gone = w.send(&bob, &general, "bob will delete this").await;
    w.send(&bob, &general, "bob stays").await;
    let (_, dm) = w
        .call("POST", &format!("/dms/{bob_id}"), &alice, None)
        .await;
    w.send(&alice, dm["channel_id"].as_str().unwrap(), DM_SECRET)
        .await;
    let uri = format!(
        "/channels/{general}/messages/{}",
        gone["id"].as_str().unwrap()
    );
    assert!(w.call("DELETE", &uri, &bob, None).await.0.is_success());

    let archive = w.archive(&alice, "space").await;

    let messages = archive.lines(&format!("channels/{general}/messages.jsonl"));
    let mut texts: Vec<&str> = messages
        .iter()
        .map(|m| m["content"].as_str().unwrap())
        .collect();
    texts.sort_unstable();
    assert_eq!(texts, ["bob stays", "hello everyone"]);
    assert!(!archive.contains(DM_SECRET), "a direct message leaked");
    assert!(!archive.contains("bob will delete this"));
    for secret in ["$argon2", "password_hash", alice.as_str(), bob.as_str()] {
        assert!(
            !archive.contains(secret),
            "{secret} leaked into the archive"
        );
    }
    let channels = archive.lines("channels.jsonl");
    assert!(channels.iter().all(|c| c["kind"] != "dm"));
    assert_eq!(archive.lines("members.jsonl").len(), 2);
    assert_eq!(archive.json("manifest.json")["kind"], "space");
}

#[tokio::test]
async fn a_deleted_account_is_gone_from_members_and_authorship() {
    let (store, _guard) = support::new_store("slimm-export-space-erased").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let general = general_channel_id(&store).await;
    w.send(&bob, &general, "said before leaving").await;
    store.delete_account(user_id(&bob_id)).await.unwrap();

    let archive = w.archive(&alice, "space").await;

    let messages = archive.lines(&format!("channels/{general}/messages.jsonl"));
    assert_eq!(messages[0]["content"], "said before leaving");
    assert!(messages[0]["author_id"].is_null());
    assert!(!archive.contains(&bob_id));
    assert_eq!(archive.lines("members.jsonl").len(), 1);
}

#[tokio::test]
async fn only_an_administrator_may_export_the_space() {
    let (store, _guard) = support::new_store("slimm-export-space-permission").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let manager = store
        .create_role("manager", Permissions::MANAGE_SERVER, false)
        .await
        .unwrap();
    store.assign_role(user_id(&bob_id), manager).await.unwrap();

    let (as_member, _) = w.start(&bob, "space").await;
    let (as_admin, _) = w.start(&alice, "space").await;

    assert_eq!(
        as_member,
        StatusCode::FORBIDDEN,
        "MANAGE_SERVER must not be enough"
    );
    assert_eq!(as_admin, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn starting_and_downloading_a_space_export_are_audited() {
    let (store, _guard) = support::new_store("slimm-export-space-audit").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let job = w.export(&alice, "space").await;
    let id = job["id"].as_str().unwrap();
    assert_eq!(w.download(&alice, id).await.0, StatusCode::OK);

    let (_, log) = w.call("GET", "/space/audit-log", &alice, None).await;

    let actions: Vec<&str> = log
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["action"].as_str().unwrap())
        .collect();
    assert!(actions.contains(&"space.export"), "{actions:?}");
    assert!(actions.contains(&"space.export_download"), "{actions:?}");
}

#[tokio::test]
async fn a_long_channel_streams_through_and_progress_reaches_the_total() {
    let (store, _guard) = support::new_store("slimm-export-space-long").await;
    let w = world(store.clone());
    let (alice, alice_id) = account(&store, "alice").await;
    let general = general_channel_id(&store).await;
    // More than the row buffer between the reader and the writer.
    for n in 0..600 {
        let content = format!("message {n}");
        let message = NewMessage::plain(
            ChannelId(general.parse().unwrap()),
            user_id(&alice_id),
            MessageId::generate(),
            &content,
        );
        store.send_message(message).await.unwrap();
    }

    let job = w.export(&alice, "space").await;

    assert_eq!(job["status"], "ready");
    assert_eq!(job["processed"], job["total"]);
    assert_eq!(job["total"], 600);
    let (_, bytes) = w.download(&alice, job["id"].as_str().unwrap()).await;
    let archive = support::exports::Archive::parse(&bytes);
    let lines = archive.lines(&format!("channels/{general}/messages.jsonl"));
    assert_eq!(lines.len(), 600);
    assert_eq!(lines[599]["content"], "message 599");
}
