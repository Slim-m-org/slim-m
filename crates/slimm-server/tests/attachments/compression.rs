// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space's photo compression: the admin setting, and what an upload
//! becomes with it on and off.

use axum::Router;
use axum::http::{StatusCode, header};
use image::codecs::jpeg::JpegEncoder;
use image::{ExtendedColorType, ImageEncoder, RgbImage};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::Duration;

use slimm_server::media::{CompressionBudget, Media};
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::fixtures::*;

const GPS_RATIONALS: [u8; 24] = [
    52, 0, 0, 0, 1, 0, 0, 0, 31, 0, 0, 0, 1, 0, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0,
];

/// An orientation and a GPS position in a little-endian TIFF block.
fn exif_with_position(orientation: u8) -> Vec<u8> {
    let mut out = b"II*\0\x08\0\0\0".to_vec();
    out.extend_from_slice(&2u16.to_le_bytes());
    for (tag, kind, count, field) in [
        (0x0112u16, 3u16, 1u32, [orientation, 0, 0, 0]),
        (0x8825, 4, 1, 38u32.to_le_bytes()),
    ] {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&kind.to_le_bytes());
        out.extend_from_slice(&count.to_le_bytes());
        out.extend_from_slice(&field);
    }
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&5u16.to_le_bytes());
    out.extend_from_slice(&3u32.to_le_bytes());
    out.extend_from_slice(&56u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&GPS_RATIONALS);
    out
}

fn noisy_photo(width: u32, height: u32) -> RgbImage {
    let mut state = 0x2545_f491_u32;
    RgbImage::from_fn(width, height, |x, y| {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let noise = (state >> 27) as u8;
        image::Rgb([
            ((x * 255 / width) as u8).saturating_add(noise),
            ((y * 255 / height) as u8).saturating_add(noise),
            (((x + y) * 255 / (width + height)) as u8).saturating_add(noise),
        ])
    })
}

/// A q98 JPEG of a noisy gradient carrying a position and an orientation.
fn phone_photo() -> Vec<u8> {
    let img = noisy_photo(640, 480);
    let mut jpeg = Vec::new();
    JpegEncoder::new_with_quality(&mut jpeg, 98)
        .encode(img.as_raw(), 640, 480, ExtendedColorType::Rgb8)
        .unwrap();
    let tiff = exif_with_position(6);
    let mut segment = b"Exif\0\0".to_vec();
    segment.extend_from_slice(&tiff);
    let mut out = jpeg[..2].to_vec();
    out.extend_from_slice(&[0xFF, 0xE1]);
    out.extend_from_slice(&u16::try_from(segment.len() + 2).unwrap().to_be_bytes());
    out.extend_from_slice(&segment);
    out.extend_from_slice(&jpeg[2..]);
    out
}

fn screenshot() -> RgbImage {
    RgbImage::from_fn(400, 300, |x, y| {
        if (x / 8 + y / 8) % 7 == 0 {
            image::Rgb([20, 20, 24])
        } else {
            image::Rgb([240, 240, 245])
        }
    })
}

fn png_of(img: &RgbImage) -> Vec<u8> {
    let mut out = Vec::new();
    image::codecs::png::PngEncoder::new_with_quality(
        &mut out,
        image::codecs::png::CompressionType::Fast,
        image::codecs::png::FilterType::NoFilter,
    )
    .write_image(
        img.as_raw(),
        img.width(),
        img.height(),
        ExtendedColorType::Rgb8,
    )
    .unwrap();
    out
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn sha_hex(bytes: &[u8]) -> String {
    slimm_server::media::to_hex(&Sha256::digest(bytes))
}

struct Space {
    app: Router,
    store: Store,
    admin: String,
    member: String,
    _guard: crate::support::TestDbGuard,
}

async fn space() -> Space {
    space_with(Media::for_tests()).await
}

async fn space_with(media: Media) -> Space {
    let (store, guard) = new_store().await;
    let (admin, _) = register(&store, "root").await;
    let account = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    let member = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let app = app_with_media(store.clone(), media);
    Space {
        app,
        store,
        admin,
        member,
        _guard: guard,
    }
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

async fn configure(space: &Space, patch: Value) -> (StatusCode, Value) {
    send(
        &space.app,
        request_json("PATCH", "/space/media-compression", &space.admin, patch),
    )
    .await
}

async fn upload_as(space: &Space, filename: &str, bytes: Vec<u8>) -> Value {
    upload(&space.app, &space.member, filename, bytes).await
}

async fn fetch(space: &Space, id: &str, query: &str) -> (StatusCode, header::HeaderMap, Vec<u8>) {
    let response = space
        .app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{id}{query}"),
            &space.member,
        ))
        .await
        .unwrap();
    let (status, headers) = (response.status(), response.headers().clone());
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, headers, body.to_vec())
}

#[tokio::test]
async fn the_setting_starts_off_with_the_photo_defaults() {
    let space = space().await;
    let (status, body) = send(
        &space.app,
        request_plain("GET", "/space/media-compression", &space.admin),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["enabled"], json!(false));
    assert_eq!(body["metadata"], json!("remove_location"));
    assert_eq!(body["keep_original"], json!(false));
    assert_eq!(body["extensions"], body["default_extensions"]);
    assert!(
        body["extensions"]
            .as_array()
            .unwrap()
            .contains(&json!("heic"))
    );
}

#[tokio::test]
async fn only_an_admin_reads_or_changes_it_and_a_change_is_audited() {
    let space = space().await;
    let (status, _) = send(
        &space.app,
        request_plain("GET", "/space/media-compression", &space.member),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let denied = send(
        &space.app,
        request_json(
            "PATCH",
            "/space/media-compression",
            &space.member,
            json!({"enabled": true}),
        ),
    )
    .await;
    assert_eq!(denied.0, StatusCode::FORBIDDEN);

    let (status, body) =
        configure(&space, json!({"enabled": true, "metadata": "remove_all"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["enabled"], json!(true));
    assert_eq!(body["metadata"], json!("remove_all"));
    let (_, log) = send(
        &space.app,
        request_plain("GET", "/space/audit-log", &space.admin),
    )
    .await;
    assert_eq!(log[0]["action"], json!("space.media_compression"));
}

#[tokio::test]
async fn bad_values_are_refused_and_an_empty_list_restores_the_defaults() {
    let space = space().await;
    for patch in [
        json!({"metadata": "strip-everything"}),
        json!({"extensions": ["gif"]}),
        json!({"extensions": ["j p g"]}),
    ] {
        let (status, _) = configure(&space, patch.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{patch}");
    }
    let (_, narrowed) = configure(&space, json!({"extensions": ["PNG", ".jpe"]})).await;
    assert_eq!(narrowed["extensions"], json!(["png", "jpe"]));
    let (_, restored) = configure(&space, json!({"extensions": []})).await;
    assert_eq!(restored["extensions"], restored["default_extensions"]);
}

#[tokio::test]
async fn with_compression_off_an_upload_is_stored_byte_for_byte() {
    let space = space().await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;
    assert_eq!(stored["id"], json!(sha_hex(&photo)));
    assert_eq!(stored["size"], json!(photo.len()));
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert_eq!(body, photo);
}

#[tokio::test]
async fn a_large_photo_is_stored_smaller_upright_and_without_its_position() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;

    let size = stored["size"].as_u64().unwrap() as usize;
    assert!(size * 10 < photo.len() * 9, "{size} of {}", photo.len());
    assert_eq!(stored["content_type"], json!("image/jpeg"));
    assert!(stored.get("original").is_none());
    let (status, headers, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body.len(), size);
    assert_eq!(sha_hex(&body), stored["id"].as_str().unwrap());
    assert_eq!(headers[header::CONTENT_TYPE], "image/jpeg");
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (480, 640));
    assert!(!contains(&body, &GPS_RATIONALS));
    let quota = space.store.total_attachment_bytes().await.unwrap();
    assert_eq!(quota, size as i64, "the quota counts the stored bytes");
}

#[tokio::test]
async fn keeping_all_metadata_keeps_the_position() {
    let space = space().await;
    configure(&space, json!({"enabled": true, "metadata": "keep"})).await;
    let stored = upload_as(&space, "IMG_0001.jpg", phone_photo()).await;
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert!(contains(&body, &GPS_RATIONALS));
}

#[tokio::test]
async fn a_screenshot_stays_lossless_and_a_photo_in_a_png_becomes_a_jpeg() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let img = screenshot();
    let stored = upload_as(&space, "Screenshot.png", png_of(&img)).await;
    assert_eq!(stored["content_type"], json!("image/png"));
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    let decoded = image::load_from_memory(&body).unwrap().to_rgb8();
    assert_eq!(decoded.as_raw(), img.as_raw());

    let photo = upload_as(&space, "scan.png", png_of(&noisy_photo(320, 240))).await;
    assert_eq!(photo["content_type"], json!("image/jpeg"));
    assert_eq!(photo["filename"], json!("scan.jpg"));
}

#[tokio::test]
async fn an_animated_gif_and_a_video_pass_through_untouched() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let gif = b"GIF89a\x01\0\x01\0\x80\0\0\0\0\0\xff\xff\xff!\xf9\x04\0\x0a\0\0\0,\0\0\0\0\x01\0\x01\0\0\x02\x02D\x01\0!\xf9\x04\0\x0a\0\0\0,\0\0\0\0\x01\0\x01\0\0\x02\x02D\x01\0;".to_vec();
    let mut mp4 = b"\0\0\0\x18ftypmp42\0\0\0\0mp42isom".to_vec();
    mp4.extend(std::iter::repeat_n(7u8, 4000));
    for (name, bytes) in [("loop.gif", gif), ("clip.mp4", mp4)] {
        let stored = upload_as(&space, name, bytes.clone()).await;
        assert_eq!(stored["id"], json!(sha_hex(&bytes)), "{name}");
        assert_eq!(stored["size"], json!(bytes.len()), "{name}");
    }
}

#[tokio::test]
async fn only_the_listed_types_are_compressed() {
    let space = space().await;
    configure(&space, json!({"enabled": true, "extensions": ["png"]})).await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;
    assert_eq!(stored["id"], json!(sha_hex(&photo)));
}

#[tokio::test]
async fn a_heic_is_converted_to_a_jpeg_every_client_draws() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let heic = include_bytes!("tiny.heic").to_vec();
    let stored = upload_as(&space, "IMG_0002.HEIC", heic).await;
    assert_eq!(stored["content_type"], json!("image/jpeg"));
    assert_eq!(stored["filename"], json!("IMG_0002.jpg"));
}

#[tokio::test]
async fn keeping_the_original_serves_the_copy_inline_and_the_original_as_a_download() {
    let space = space().await;
    configure(&space, json!({"enabled": true, "keep_original": true})).await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;
    let id = stored["id"].as_str().unwrap();
    assert_eq!(
        stored["original"],
        json!({"size": photo.len(), "filename": "IMG_0001.jpg"})
    );

    let (_, inline, copy) = fetch(&space, id, "").await;
    assert!(
        inline[header::CONTENT_DISPOSITION]
            .to_str()
            .unwrap()
            .starts_with("inline")
    );
    assert!(copy.len() < photo.len());

    let (status, download, original) = fetch(&space, id, "?original=true").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(original, photo);
    let disposition = download[header::CONTENT_DISPOSITION].to_str().unwrap();
    assert!(disposition.starts_with("attachment"), "{disposition}");
    assert!(disposition.contains("IMG_0001.jpg"), "{disposition}");

    let quota = space.store.total_attachment_bytes().await.unwrap();
    assert_eq!(quota, (copy.len() + photo.len()) as i64);
}

#[tokio::test]
async fn an_original_that_was_not_kept_is_not_found() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let stored = upload_as(&space, "IMG_0001.jpg", phone_photo()).await;
    let (status, _, _) = fetch(&space, stored["id"].as_str().unwrap(), "?original=true").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn a_resumable_upload_is_compressed_too() {
    let space = space().await;
    configure(&space, json!({"enabled": true, "keep_original": true})).await;
    let photo = phone_photo();
    let (_, session) = send(
        &space.app,
        request_json(
            "POST",
            "/attachments/uploads",
            &space.member,
            json!({"filename": "IMG_0001.jpg", "size": photo.len()}),
        ),
    )
    .await;
    let id = session["id"].as_str().unwrap();
    let (half, rest) = photo.split_at(photo.len() / 2);
    for (offset, part) in [(0, half), (half.len(), rest)] {
        let (status, _) = send(
            &space.app,
            request_bytes(
                "PUT",
                &format!("/attachments/uploads/{id}?offset={offset}"),
                &space.member,
                part.to_vec(),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let (status, stored) = send(
        &space.app,
        request_plain(
            "POST",
            &format!("/attachments/uploads/{id}/complete"),
            &space.member,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert!((stored["size"].as_u64().unwrap() as usize) < photo.len());
    assert_eq!(
        stored["original"],
        json!({"size": photo.len(), "filename": "IMG_0001.jpg"})
    );
    let (_, _, original) = fetch(&space, stored["id"].as_str().unwrap(), "?original=true").await;
    assert_eq!(original, photo);
}

const MIB: u64 = 1024 * 1024;

#[tokio::test]
async fn a_photo_too_big_for_the_memory_budget_is_stored_as_sent() {
    let tiny = CompressionBudget::new(8 * MIB, Duration::from_millis(50));
    let space = space_with(Media::for_tests().with_compression_budget(tiny)).await;
    configure(&space, json!({"enabled": true})).await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;
    assert_eq!(stored["id"], json!(sha_hex(&photo)));
    assert_eq!(stored["size"], json!(photo.len()));
}

#[tokio::test]
async fn jobs_that_fit_one_at_a_time_queue_and_all_compress() {
    let room_for_one = CompressionBudget::new(40 * MIB, Duration::from_secs(30));
    let space = space_with(Media::for_tests().with_compression_budget(room_for_one)).await;
    configure(&space, json!({"enabled": true})).await;
    let photo = phone_photo();
    let names: Vec<String> = (0..3).map(|i| format!("IMG_{i}.jpg")).collect();
    let uploads = names
        .iter()
        .map(|name| upload_as(&space, name, photo.clone()));
    let stored = futures_util::future::join_all(uploads).await;
    for one in stored {
        assert!(one["size"].as_u64().unwrap() < photo.len() as u64 * 9 / 10);
    }
}
