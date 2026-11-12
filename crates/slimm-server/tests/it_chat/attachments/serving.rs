// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `GET /attachments/{id}` answers: who is allowed to fetch at all, and
//! what headers and bytes come back when they are.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;

/// The single most important test here: a channel permission, not an
/// unguessable id, is what gates a fetch. Bob can authenticate but holds no
/// role granting VIEW_CHANNEL in the channel alice attached the file to, and
/// must be refused even though he has the exact, correct attachment id.
#[tokio::test]
async fn fetching_requires_view_channel_permission() {
    let (store, _guard) = new_store().await;
    // @everyone gets nothing; alice is separately granted what she needs so
    // bob (plain @everyone) genuinely cannot view the channel.
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let can_post = store
        .create_role(
            "poster",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            false,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    store.assign_role(alice_id, can_post).await.unwrap();
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let uploaded = upload(&app, &alice_token, "secret.png", png(16)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();

    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &alice_token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "look at this",
                "attachment_ids": [attachment_id],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    let sent = json_body(sent).await;
    assert_eq!(
        sent["attachments"].as_array().unwrap().len(),
        1,
        "a fresh send must echo its own attachment immediately"
    );

    let fetch_uri = format!("/attachments/{attachment_id}");

    // Bob cannot see the channel, so he cannot fetch the attachment either,
    // despite knowing its exact, correct id.
    let refused = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &bob_token))
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::NOT_FOUND,
        "an unguessable id is not access control"
    );

    // And it is 404, not 403: an attachment id is the content's sha256, so a
    // 403-versus-404 split would let bob confirm those exact bytes were shared
    // in a channel he cannot see. Bytes nothing ever attached answer the same
    // 404, so the two are indistinguishable and the oracle is closed.
    let unknown_id = "0".repeat(64);
    let unknown = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{unknown_id}"),
            &bob_token,
        ))
        .await
        .unwrap();
    assert_eq!(
        unknown.status(),
        refused.status(),
        "a hidden attachment and a never-uploaded one must look identical"
    );

    // Control: alice, who can view the channel, can fetch it.
    let allowed = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &alice_token))
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
}

#[tokio::test]
async fn the_served_response_carries_nosniff_and_a_safe_disposition() {
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

    let uploaded = upload(&app, &token, "photo.png", png(8)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    app.clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "a photo",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{attachment_id}"),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let headers = response.headers().clone();
    assert_eq!(headers.get("x-content-type-options").unwrap(), "nosniff");
    assert_eq!(headers.get("content-type").unwrap(), "image/png");
    let disposition = headers
        .get("content-disposition")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(
        disposition.starts_with("inline"),
        "a known-safe image type may render inline: {disposition}"
    );
    assert!(disposition.contains("photo.png"));
}

#[tokio::test]
async fn a_non_image_attachment_is_served_as_a_forced_download() {
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

    let pdf = b"%PDF-1.7 rest of a not-really-a-pdf".to_vec();
    let uploaded = upload(&app, &token, "doc.pdf", pdf).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    assert_eq!(uploaded["content_type"], "application/pdf");
    app.clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "a document",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();

    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{attachment_id}"),
            &token,
        ))
        .await
        .unwrap();
    let disposition = response
        .headers()
        .get("content-disposition")
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    assert!(
        disposition.starts_with("attachment"),
        "everything but an allowlisted image type must force a download: {disposition}"
    );
}

/// The uploader may fetch their own attachment before it is on any message -
/// the staged-GIF preview flow, which selects (uploads) then immediately
/// fetches for the composer's local preview, and used to 404 every time
/// because the fetch only checked message-referenced channels. A different
/// user still 404s on those same unreferenced bytes: existence follows
/// permission for everyone but the uploader.
#[tokio::test]
async fn the_uploader_can_fetch_their_own_not_yet_attached_upload() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;

    // Uploaded, never attached to a message: exactly the mid-compose state.
    let uploaded = upload(&app, &alice_token, "staged.png", png(16)).await;
    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let fetch_uri = format!("/attachments/{attachment_id}");

    let mine = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &alice_token))
        .await
        .unwrap();
    assert_eq!(
        mine.status(),
        StatusCode::OK,
        "the uploader must be able to preview what they just uploaded"
    );

    let theirs = app
        .clone()
        .oneshot(request_plain("GET", &fetch_uri, &bob_token))
        .await
        .unwrap();
    assert_eq!(
        theirs.status(),
        StatusCode::NOT_FOUND,
        "a non-uploader still cannot fetch unreferenced bytes"
    );
}
