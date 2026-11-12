// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may link an already-uploaded attachment to a message. Before this,
//! `link_attachments` authorized nothing beyond the id existing somewhere in
//! `attachments`, so anyone who learned an id could attach it to a message
//! in a channel they could post in, whether or not they ever uploaded it or
//! could see where it had been shared.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

/// The finding itself. Bob never uploaded alice's file and cannot view the
/// channel she shared it in, but he can post in a channel of his own and
/// knows the exact id (attachment ids are the content's own sha256, so any
/// holder of a candidate file can compute one). Linking must be refused, and
/// refused identically to how a completely fictional id is refused: the
/// point of the finding is that this is not merely a 400, but a 400 with no
/// oracle in it.
#[tokio::test]
async fn linking_an_id_you_never_uploaded_and_cannot_view_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let poster = store
        .create_role(
            "poster",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            false,
        )
        .await
        .unwrap();
    let private_channel = store.create_channel("private", "text").await.unwrap();
    let public_channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    store.assign_role(alice_id, poster).await.unwrap();
    let (bob_token, bob_id) = register(&store, "bob").await;
    store.assign_role(bob_id, poster).await.unwrap();
    // The one restriction making bob unable to view where alice shared it.
    store
        .set_member_overwrite(
            private_channel.id,
            bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let uploaded = upload(&app, &alice_token, "secret.png", png(16)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();

    let shared = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", private_channel.id),
            &alice_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "just between us",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(shared.status(), StatusCode::OK);

    let bob_attempt = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", public_channel.id),
            &bob_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "look what I found",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(bob_attempt.status(), StatusCode::BAD_REQUEST);
    let bob_body = json_body(bob_attempt).await;

    let never_uploaded_id = "ab".repeat(32);
    let control = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", public_channel.id),
            &bob_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "look what I found",
                "attachment_ids": [never_uploaded_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(control.status(), StatusCode::BAD_REQUEST);
    let control_body = json_body(control).await;

    assert_eq!(
        bob_body, control_body,
        "an id bob cannot reach and one that was never uploaded must read identically"
    );
}

/// Control: linking bytes you uploaded yourself is the ordinary case and
/// must keep working.
#[tokio::test]
async fn linking_your_own_upload_still_works() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    let uploaded = upload(&app, &token, "mine.png", png(4)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();

    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "my own file",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
}

/// The revocation half of the finding: seeing an id in a channel you could
/// once view does not grant a standing right to link it. Bob genuinely could
/// view the channel alice shared the file in, so the fallback (uploaded, or
/// currently able to view a channel that has it) is what a real forward
/// relies on - but once his view access is revoked, he holds neither
/// condition and re-linking the same id elsewhere must be refused.
#[tokio::test]
async fn re_linking_after_losing_view_access_is_refused() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let poster = store
        .create_role(
            "poster",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            false,
        )
        .await
        .unwrap();
    let shared_channel = store.create_channel("shared", "text").await.unwrap();
    let other_channel = store.create_channel("elsewhere", "text").await.unwrap();
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    store.assign_role(alice_id, poster).await.unwrap();
    let (bob_token, bob_id) = register(&store, "bob").await;
    store.assign_role(bob_id, poster).await.unwrap();

    let uploaded = upload(&app, &alice_token, "seen-by-bob.png", png(8)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let shared = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", shared_channel.id),
            &alice_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "look",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(shared.status(), StatusCode::OK);

    // Sanity: bob genuinely can fetch it, through the same channel permission the fallback reads.
    let seen = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{attachment_id}"),
            &bob_token,
        ))
        .await
        .unwrap();
    assert_eq!(
        seen.status(),
        StatusCode::OK,
        "sanity: bob can see it first"
    );

    // Revoke bob's view access to the only channel that has ever referenced it.
    store
        .set_member_overwrite(
            shared_channel.id,
            bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let refused = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", other_channel.id),
            &bob_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "forwarding",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::BAD_REQUEST,
        "lost view access must not leave a standing right to link"
    );
}

/// The regression guard for the join-table decision in migration 0023. A
/// single overwritable `uploader_id` would have let bob's re-upload evict
/// alice's linking rights; a single first-wins `uploader_id` would have
/// left bob permanently unable to link bytes he genuinely, independently
/// uploaded. Content addressing means his upload and alice's upload are the
/// same row, but the join table means both keep their own linking rights.
#[tokio::test]
async fn independently_uploading_identical_bytes_grants_linking_rights() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let poster = store
        .create_role(
            "poster",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            false,
        )
        .await
        .unwrap();
    let private_channel = store.create_channel("private", "text").await.unwrap();
    let public_channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    store.assign_role(alice_id, poster).await.unwrap();
    let (bob_token, bob_id) = register(&store, "bob").await;
    store.assign_role(bob_id, poster).await.unwrap();
    store
        .set_member_overwrite(
            private_channel.id,
            bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let bytes = png(24);
    let alice_uploaded = upload(&app, &alice_token, "shared-bytes.png", bytes.clone()).await;
    let attachment_id = alice_uploaded["id"].as_str().unwrap().to_owned();
    let shared = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", private_channel.id),
            &alice_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "private",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(shared.status(), StatusCode::OK);

    let bob_uploaded = upload(&app, &bob_token, "coincidence.png", bytes).await;
    assert_eq!(
        bob_uploaded["id"].as_str().unwrap(),
        attachment_id,
        "content addressing: identical bytes must resolve to the same id"
    );

    let linked = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", public_channel.id),
            &bob_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "my upload too",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        linked.status(),
        StatusCode::OK,
        "an independent upload of the same bytes must grant its own linking rights"
    );
}
