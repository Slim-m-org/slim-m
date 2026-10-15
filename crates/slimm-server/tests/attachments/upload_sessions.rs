// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resumable uploads (`/attachments/uploads`) and the admin's attachment
//! size limit (`/space/attachment-limit`), which both decide how large a
//! file may be.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::fixtures::*;

const MIB: u64 = 1024 * 1024;

async fn member_app(media: Media) -> (Store, crate::support::TestDbGuard, Router, String) {
    let (store, guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app_with_media(store.clone(), media);
    let (token, _) = register(&store, "alice").await;
    (store, guard, app, token)
}

/// The first account claims the deployment and so holds MANAGE_SERVER.
async fn admin_app(media: Media) -> (Store, crate::support::TestDbGuard, Router, String) {
    let (store, guard) = new_store().await;
    let (token, _) = register(&store, "root").await;
    let app = app_with_media(store.clone(), media);
    (store, guard, app, token)
}

async fn send(app: &Router, request: axum::http::Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn open(app: &Router, token: &str, size: usize) -> (StatusCode, Value) {
    send(
        app,
        request_json(
            "POST",
            "/attachments/uploads",
            token,
            json!({"filename": "big.png", "size": size}),
        ),
    )
    .await
}

async fn part(
    app: &Router,
    token: &str,
    id: &str,
    offset: usize,
    bytes: &[u8],
) -> (StatusCode, Value) {
    send(
        app,
        request_bytes(
            "PUT",
            &format!("/attachments/uploads/{id}?offset={offset}"),
            token,
            bytes.to_vec(),
        ),
    )
    .await
}

async fn complete(app: &Router, token: &str, id: &str) -> (StatusCode, Value) {
    send(
        app,
        request_plain(
            "POST",
            &format!("/attachments/uploads/{id}/complete"),
            token,
        ),
    )
    .await
}

#[tokio::test]
async fn parts_complete_into_the_same_attachment_a_single_upload_makes() {
    let (_store, _guard, app, token) = member_app(media_for_test()).await;
    let bytes = png(3000);

    let (status, session) = open(&app, &token, bytes.len()).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(session["offset"], json!(0));
    let id = session["id"].as_str().unwrap().to_owned();

    let (status, after) = part(&app, &token, &id, 0, &bytes[..1000]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(after["offset"], json!(1000));
    part(&app, &token, &id, 1000, &bytes[1000..]).await;

    let (status, stored) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(stored["content_type"], json!("image/png"));
    assert_eq!(stored["filename"], json!("big.png"));

    let direct = upload(&app, &token, "big.png", bytes.clone()).await;
    assert_eq!(stored["id"], direct["id"], "content addressing is the same");

    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{}", stored["id"].as_str().unwrap()),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let served = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(served.as_ref(), bytes.as_slice());

    let (status, _) = send(
        &app,
        request_plain("GET", &format!("/attachments/uploads/{id}"), &token),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a completed session is gone");
}

#[tokio::test]
async fn a_part_at_the_wrong_offset_is_a_conflict_and_the_status_says_where_to_resume() {
    let (_store, _guard, app, token) = member_app(media_for_test()).await;
    let bytes = png(500);
    let (_, session) = open(&app, &token, bytes.len()).await;
    let id = session["id"].as_str().unwrap().to_owned();
    part(&app, &token, &id, 0, &bytes[..200]).await;

    let (status, _) = part(&app, &token, &id, 0, &bytes[..200]).await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "a replayed part must not append twice"
    );

    let (status, now) = send(
        &app,
        request_plain("GET", &format!("/attachments/uploads/{id}"), &token),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(now["offset"], json!(200));
}

#[tokio::test]
async fn completing_early_is_a_conflict() {
    let (_store, _guard, app, token) = member_app(media_for_test()).await;
    let bytes = png(500);
    let (_, session) = open(&app, &token, bytes.len()).await;
    let id = session["id"].as_str().unwrap().to_owned();
    part(&app, &token, &id, 0, &bytes[..200]).await;

    let (status, _) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn another_members_session_reads_as_missing() {
    let (store, _guard, app, token) = member_app(media_for_test()).await;
    let bytes = png(100);
    let (_, session) = open(&app, &token, bytes.len()).await;
    let id = session["id"].as_str().unwrap().to_owned();
    let mallory = store.create_user("mallory", "Mallory").await.unwrap();
    let other = store
        .open_session(mallory.id, "cli")
        .await
        .unwrap()
        .access_token;

    let (status, _) = part(&app, &other, &id, 0, &bytes).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = complete(&app, &other, &id).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = send(
        &app,
        request_plain("DELETE", &format!("/attachments/uploads/{id}"), &other),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = part(&app, &token, &id, 0, &bytes).await;
    assert_eq!(status, StatusCode::OK, "the owner's session is untouched");
}

#[tokio::test]
async fn an_unrecognized_type_completes_as_a_generic_download() {
    let (_store, _guard, app, token) = member_app(media_for_test()).await;
    let mut bytes = vec![0u8, 1, 2, 3, 0xff, 0xfe, 0, 7];
    bytes.resize(3000, 0);
    let (_, session) = open(&app, &token, bytes.len()).await;
    let id = session["id"].as_str().unwrap().to_owned();

    let (status, _) = part(&app, &token, &id, 0, &bytes).await;
    assert_eq!(status, StatusCode::OK);
    let (status, stored) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(stored["content_type"], "application/octet-stream");
}

#[tokio::test]
async fn opening_needs_attach_files_and_a_size_within_the_limit() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let app = app(store.clone());
    let (_owner, _) = register(&store, "root").await;
    let member = store.create_user("nia", "Nia").await.unwrap();
    let token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    let (status, _) = open(&app, &token, 10).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (_s, _g, app, token) = member_app(media_for_test()).await;
    let (status, _) = open(&app, &token, TEST_MAX_ATTACHMENT_BYTES as usize + 1).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    let (status, _) = open(&app, &token, 0).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn the_admin_limit_lowers_what_every_upload_path_and_version_allow() {
    let (_store, _guard, app, token) =
        admin_app(Media::for_tests().with_attachment_max(8 * MIB)).await;

    let (status, limit) = send(
        &app,
        request_plain("GET", "/space/attachment-limit", &token),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(limit, json!({"max_bytes": 0, "server_max_bytes": 8 * MIB}));

    let (status, _) = send(
        &app,
        request_json(
            "PATCH",
            "/space/attachment-limit",
            &token,
            json!({"max_bytes": MIB}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (_, version) = send(&app, request_plain("GET", "/version", &token)).await;
    assert_eq!(version["max_attachment_bytes"], json!(MIB));
    let (status, _) = open(&app, &token, MIB as usize + 1).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    let (status, _) = send(
        &app,
        request_bytes(
            "POST",
            "/attachments?filename=big.png",
            &token,
            png(MIB as usize),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    let (status, _) = open(&app, &token, MIB as usize).await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn the_admin_limit_stays_between_one_mib_and_the_operator_ceiling() {
    let (_store, _guard, app, token) =
        admin_app(Media::for_tests().with_attachment_max(8 * MIB)).await;
    for (max_bytes, expected) in [
        (MIB - 1, StatusCode::BAD_REQUEST),
        (8 * MIB + 1, StatusCode::BAD_REQUEST),
        (MIB, StatusCode::OK),
        (8 * MIB, StatusCode::OK),
        (0, StatusCode::OK),
    ] {
        let (status, _) = send(
            &app,
            request_json(
                "PATCH",
                "/space/attachment-limit",
                &token,
                json!({"max_bytes": max_bytes}),
            ),
        )
        .await;
        assert_eq!(status, expected, "max_bytes {max_bytes}");
    }
}

#[tokio::test]
async fn the_admin_limit_needs_manage_server() {
    let (store, _guard, app, _owner) =
        admin_app(Media::for_tests().with_attachment_max(8 * MIB)).await;
    let member = store.create_user("nia", "Nia").await.unwrap();
    let token = store
        .open_session(member.id, "cli")
        .await
        .unwrap()
        .access_token;
    let (status, _) = send(
        &app,
        request_plain("GET", "/space/attachment-limit", &token),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        request_json(
            "PATCH",
            "/space/attachment-limit",
            &token,
            json!({"max_bytes": MIB}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}
