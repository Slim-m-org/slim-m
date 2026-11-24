// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resumable uploads against the storage limits: what an idle session holds,
//! what completing one counts, a replayed completion, the per-file limit
//! at completion, and the free-space floor.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use image::codecs::jpeg::JpegEncoder;
use image::{ExtendedColorType, RgbImage};
use serde_json::{Value, json};
use slimm_server::media::Media;

use crate::storage_ceiling::{
    admin, app_on, blob, media_with, new_store, open_session, png, status_of, upload,
};

fn call(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap()
}

async fn open_id(app: &Router, token: &str, size: usize) -> String {
    let (status, session) = status_of(app, open_session(token, size)).await;
    assert_eq!(status, StatusCode::CREATED);
    session["id"].as_str().unwrap().to_owned()
}

async fn put_all(app: &Router, token: &str, id: &str, bytes: &[u8]) {
    let uri = format!("/attachments/uploads/{id}?offset=0");
    let (status, _) = status_of(app, call("PUT", &uri, token, bytes.to_vec())).await;
    assert_eq!(status, StatusCode::OK);
}

async fn complete(app: &Router, token: &str, id: &str) -> (StatusCode, Value) {
    let uri = format!("/attachments/uploads/{id}/complete");
    status_of(app, call("POST", &uri, token, Vec::new())).await
}

fn go_idle(media: &Media, id: &str) {
    let path = media.uploads().data_path(id.parse().unwrap());
    let long_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(long_ago)
        .unwrap();
}

fn noisy_jpeg() -> Vec<u8> {
    let mut state = 0x2545_f491_u32;
    let img = RgbImage::from_fn(640, 480, |x, y| {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let noise = (state >> 27) as u8;
        image::Rgb([
            ((x * 255 / 640) as u8).saturating_add(noise),
            ((y * 255 / 480) as u8).saturating_add(noise),
            (((x + y) * 255 / 1120) as u8).saturating_add(noise),
        ])
    });
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 98)
        .encode(img.as_raw(), 640, 480, ExtendedColorType::Rgb8)
        .unwrap();
    out
}

#[tokio::test]
async fn an_idle_session_stops_holding_room_against_the_ceiling() {
    let (store, _guard) = new_store("slimm-upload-idle").await;
    let (_admin, token) = admin(&store, "root").await;
    let media = media_with(1000);
    let app = app_on(store, media.clone());

    let first = open_id(&app, &token, 600).await;
    let (status, _) = status_of(&app, open_session(&token, 600)).await;
    assert_eq!(
        status,
        StatusCode::INSUFFICIENT_STORAGE,
        "a fresh session holds its room"
    );

    go_idle(&media, &first);
    let (status, _) = status_of(&app, open_session(&token, 600)).await;
    assert_eq!(status, StatusCode::CREATED, "an idle one does not");
}

#[tokio::test]
async fn completing_a_compressed_photo_near_the_ceiling_counts_the_session_once() {
    let (store, _guard) = new_store("slimm-upload-photo").await;
    let (_admin, token) = admin(&store, "root").await;
    let photo = noisy_jpeg();
    let app = app_on(store.clone(), media_with(photo.len() as u64 + 100));
    let patch = call(
        "PATCH",
        "/space/media-compression",
        &token,
        json!({"enabled": true, "keep_original": false, "metadata": "keep"})
            .to_string()
            .into_bytes(),
    );
    assert_eq!(status_of(&app, patch).await.0, StatusCode::OK);

    let id = open_id(&app, &token, photo.len()).await;
    put_all(&app, &token, &id, &photo).await;
    let (status, stored) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CREATED);
    assert!((stored["size"].as_u64().unwrap() as usize) < photo.len());
}

#[tokio::test]
async fn a_ceiling_refusal_at_completion_keeps_the_upload_for_a_retry() {
    let (store, _guard) = new_store("slimm-upload-refusal-keeps").await;
    let (_admin, token) = admin(&store, "root").await;
    let media = media_with(2 * png(1).len() as u64);
    let app = app_on(store, media.clone());
    let bytes = png(2);
    let id = open_id(&app, &token, bytes.len()).await;
    put_all(&app, &token, &id, &bytes).await;
    go_idle(&media, &id);
    for tag in [3, 4] {
        let (status, _) = status_of(&app, upload(&token, png(tag))).await;
        assert_eq!(status, StatusCode::CREATED);
    }

    assert_eq!(
        complete(&app, &token, &id).await.0,
        StatusCode::INSUFFICIENT_STORAGE
    );
    let status = call(
        "GET",
        &format!("/attachments/uploads/{id}"),
        &token,
        Vec::new(),
    );
    assert_eq!(
        status_of(&app, status).await.0,
        StatusCode::OK,
        "the bytes are still there"
    );
}

#[tokio::test]
async fn a_replayed_completion_returns_the_same_attachment() {
    let (store, _guard) = new_store("slimm-upload-replay").await;
    let (_admin, token) = admin(&store, "root").await;
    let account = store
        .create_account("other", "other", "not-a-real-hash")
        .await
        .unwrap();
    let stranger = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = app_on(store, Media::for_tests());
    let bytes = png(7);
    let id = open_id(&app, &token, bytes.len()).await;
    put_all(&app, &token, &id, &bytes).await;

    let (status, first) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, again) = complete(&app, &token, &id).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(first, again);
    assert_eq!(
        complete(&app, &stranger, &id).await.0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn completing_refuses_a_file_over_the_limit_set_after_it_opened() {
    let (store, _guard) = new_store("slimm-upload-limit").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app_on(store, Media::for_tests().with_attachment_max(8 << 20));
    let size = (1 << 20) + 1;
    let id = open_id(&app, &token, size).await;
    put_all(&app, &token, &id, &blob_of(size)).await;
    let lower = call(
        "PATCH",
        "/space/attachment-limit",
        &token,
        json!({"max_bytes": 1 << 20}).to_string().into_bytes(),
    );
    assert_eq!(status_of(&app, lower).await.0, StatusCode::OK);

    assert_eq!(
        complete(&app, &token, &id).await.0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
}

fn blob_of(size: usize) -> Vec<u8> {
    blob(9).into_iter().cycle().take(size).collect()
}

#[tokio::test]
async fn a_volume_below_the_free_space_floor_refuses_new_uploads() {
    let (store, _guard) = new_store("slimm-upload-floor").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app_on(
        store,
        Media::for_tests().with_min_free_bytes(Some(u64::MAX / 2)),
    );

    let (status, _) = status_of(&app, upload(&token, png(1))).await;
    assert_eq!(status, StatusCode::INSUFFICIENT_STORAGE);
    let (status, _) = status_of(&app, open_session(&token, 100)).await;
    assert_eq!(status, StatusCode::INSUFFICIENT_STORAGE);
}

#[tokio::test]
async fn a_volume_with_room_above_the_floor_takes_uploads() {
    let (store, _guard) = new_store("slimm-upload-floor-ok").await;
    let (_admin, token) = admin(&store, "root").await;
    let app = app_on(store, Media::for_tests().with_min_free_bytes(Some(1)));

    let (status, _) = status_of(&app, upload(&token, png(1))).await;
    assert_eq!(status, StatusCode::CREATED);
}
