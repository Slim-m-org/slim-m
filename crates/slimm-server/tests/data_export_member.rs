// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's data export: only their own words and files, never anyone
//! else's, never anything deleted, and gated by their password.

use axum::http::StatusCode;
use serde_json::json;

mod support;

use support::app::general_channel_id;
use support::exports::{account, upload_png, world};

const BOB_PUBLIC: &str = "BOB-PUBLIC-SECRET-TEXT";
const BOB_DM: &str = "BOB-TO-ALICE-DM-SECRET";
const BOB_CAROL_DM: &str = "BOB-TO-CAROL-DM-SECRET";
const CAROL_DM: &str = "CAROL-TO-BOB-DM-SECRET";

#[tokio::test]
async fn a_member_export_holds_only_their_own_words() {
    let (store, _guard) = support::new_store("slimm-export-member-own").await;
    let w = world(store.clone());
    let (alice, _alice_id) = account(&store, "alice").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let (carol, carol_id) = account(&store, "carol").await;
    let general = general_channel_id(&store).await;

    w.send(&alice, &general, "alice in general").await;
    let bob_message = w.send(&bob, &general, BOB_PUBLIC).await;
    let (_, with_bob) = w
        .call("POST", &format!("/dms/{bob_id}"), &alice, None)
        .await;
    let alice_bob = with_bob["channel_id"].as_str().unwrap().to_owned();
    w.send(&alice, &alice_bob, "alice to bob in a dm").await;
    w.send(&bob, &alice_bob, BOB_DM).await;
    let (_, bob_carol) = w
        .call("POST", &format!("/dms/{carol_id}"), &bob, None)
        .await;
    let bob_carol = bob_carol["channel_id"].as_str().unwrap().to_owned();
    w.send(&bob, &bob_carol, BOB_CAROL_DM).await;
    w.send(&carol, &bob_carol, CAROL_DM).await;
    let doomed = w.send(&alice, &general, "alice deleted this one").await;
    let bob_message_id = bob_message["id"].as_str().unwrap();
    for (method, uri) in [
        ("PUT", format!("/messages/{bob_message_id}/save")),
        (
            "PUT",
            format!("/messages/{bob_message_id}/reactions/%F0%9F%91%8D"),
        ),
        (
            "DELETE",
            format!(
                "/channels/{general}/messages/{}",
                doomed["id"].as_str().unwrap()
            ),
        ),
    ] {
        let (status, _) = w.call(method, &uri, &alice, None).await;
        assert!(status.is_success(), "{method} {uri}: {status}");
    }

    let archive = w.archive(&alice, "member").await;

    let messages = archive.lines("messages.jsonl");
    let mut texts: Vec<&str> = messages
        .iter()
        .map(|m| m["content"].as_str().unwrap())
        .collect();
    texts.sort_unstable();
    assert_eq!(texts, ["alice in general", "alice to bob in a dm"]);
    let dm = messages.iter().find(|m| m["channel_kind"] == "dm").unwrap();
    assert!(dm["channel_name"].is_null());
    for secret in [
        BOB_PUBLIC,
        BOB_DM,
        BOB_CAROL_DM,
        CAROL_DM,
        "alice deleted this one",
    ] {
        assert!(
            !archive.contains(secret),
            "{secret} leaked into the archive"
        );
    }
    let saved = archive.lines("saved.jsonl");
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0]["message_id"], bob_message["id"]);
    assert_eq!(saved[0]["is_own"], false);
    assert!(saved[0]["content"].is_null());
    assert_eq!(archive.lines("reactions.jsonl").len(), 1);
    assert_eq!(archive.json("profile.json")["username"], "alice");
    let manifest = archive.json("manifest.json");
    assert_eq!(manifest["format"], "slimm-export");
    assert_eq!(manifest["format_version"], 1);
    assert!(!manifest["not_included"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn a_deleted_channel_and_a_deleted_message_stay_out() {
    let (store, _guard) = support::new_store("slimm-export-member-deleted").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let general = general_channel_id(&store).await;
    let side = store.create_channel("side", "text").await.unwrap();
    w.send(&alice, &general, "kept").await;
    w.send(&alice, &side.id.to_string(), "in a channel that goes away")
        .await;
    assert!(store.delete_channel(side.id).await.unwrap());

    let archive = w.archive(&alice, "member").await;

    let texts: Vec<_> = archive.lines("messages.jsonl");
    assert_eq!(texts.len(), 1);
    assert!(!archive.contains("in a channel that goes away"));
}

#[tokio::test]
async fn uploaded_files_ride_along_with_an_index() {
    let (store, _guard) = support::new_store("slimm-export-member-files").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let general = general_channel_id(&store).await;
    let sha = upload_png(&w, &alice).await;
    let (status, _) = w
        .call(
            "POST",
            &format!("/channels/{general}/messages"),
            &alice,
            Some(json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "look", "attachment_ids": [sha] })),
        )
        .await;
    assert!(status.is_success());

    let archive = w.archive(&alice, "member").await;

    let index = archive.lines("attachments.jsonl");
    assert_eq!(index[0]["sha256"], sha.as_str());
    assert!(archive.entries.contains_key(&format!("attachments/{sha}")));
    let message = &archive.lines("messages.jsonl")[0];
    assert_eq!(message["attachments"][0]["included"], true);
}

#[tokio::test]
async fn the_password_is_required_and_must_be_right() {
    let (store, _guard) = support::new_store("slimm-export-member-password").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;

    let (missing, _) = w.start_with(&alice, "member", None).await;
    let (wrong, _) = w
        .start_with(
            &alice,
            "member",
            Some(json!({ "password": "nope-nope-nope" })),
        )
        .await;
    let (anonymous, _) = w.call("POST", "/exports/member", "bad-token", None).await;

    assert_eq!(missing, StatusCode::BAD_REQUEST);
    assert_eq!(wrong, StatusCode::FORBIDDEN);
    assert_eq!(anonymous, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn nobody_else_can_see_or_download_my_export() {
    let (store, _guard) = support::new_store("slimm-export-member-private").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let (bob, _) = account(&store, "bob").await;
    let job = w.export(&alice, "member").await;
    let id = job["id"].as_str().unwrap();

    let (show, _) = w.call("GET", &format!("/exports/{id}"), &bob, None).await;
    let (download, _) = w.download(&bob, id).await;
    let (delete, _) = w
        .call("DELETE", &format!("/exports/{id}"), &bob, None)
        .await;
    let (_, listed) = w.call("GET", "/exports", &bob, None).await;

    assert_eq!(show, StatusCode::NOT_FOUND);
    assert_eq!(download, StatusCode::NOT_FOUND);
    assert_eq!(delete, StatusCode::NOT_FOUND);
    assert_eq!(listed, json!([]));
}

#[tokio::test]
async fn a_second_export_waits_and_reports_how_long() {
    let (store, _guard) = support::new_store("slimm-export-member-pacing").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    w.export(&alice, "member").await;

    let (status, wait) = w.start_retry_after(&alice, "member").await;

    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert!(wait.unwrap() > 0);
}

#[tokio::test]
async fn deleting_the_account_removes_its_exports() {
    let (store, _guard) = support::new_store("slimm-export-member-erased").await;
    let w = world(store.clone());
    let (_admin, _) = account(&store, "admin").await;
    let (bob, bob_id) = account(&store, "bob").await;
    let job = w.export(&bob, "member").await;
    let id = job["id"].as_str().unwrap().to_owned();
    assert!(w.media.export_archive_path(&id).exists());

    store
        .delete_account(
            bob_id
                .parse::<uuid::Uuid>()
                .map(slimm_server::ids::UserId)
                .unwrap(),
        )
        .await
        .unwrap();
    slimm_server::export::sweep_exports_once(&store, &w.media)
        .await
        .unwrap();

    assert!(!w.media.export_archive_path(&id).exists());
    assert!(
        store
            .data_export(slimm_server::ids::ExportId(id.parse().unwrap()))
            .await
            .unwrap()
            .is_none()
    );
}
