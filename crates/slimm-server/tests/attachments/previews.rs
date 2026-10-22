// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /attachments/{id}?w=N`: a bounded-size preview of a still image, with
//! the original as the answer for anything that cannot or need not shrink.

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use image::codecs::jpeg::JpegEncoder;
use image::{ExtendedColorType, RgbImage};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::*;

/// A photo-like raster: a gradient with per-pixel noise, so it neither
/// compresses to nothing nor looks like flat graphics.
pub(crate) fn photo(width: u32, height: u32) -> RgbImage {
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

pub(crate) fn jpeg(img: &RgbImage, quality: u8) -> Vec<u8> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .encode(
            img.as_raw(),
            img.width(),
            img.height(),
            ExtendedColorType::Rgb8,
        )
        .unwrap();
    out
}

/// Inserts an EXIF APP1 segment carrying only an Orientation tag after the SOI marker.
fn with_orientation(jpeg: &[u8], orientation: u16) -> Vec<u8> {
    let mut tiff = b"II*\0\x08\0\0\0".to_vec();
    tiff.extend_from_slice(&1u16.to_le_bytes());
    tiff.extend_from_slice(&0x0112u16.to_le_bytes());
    tiff.extend_from_slice(&3u16.to_le_bytes());
    tiff.extend_from_slice(&1u32.to_le_bytes());
    tiff.extend_from_slice(&orientation.to_le_bytes());
    tiff.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
    let mut segment = b"Exif\0\0".to_vec();
    segment.extend_from_slice(&tiff);
    let mut out = jpeg[..2].to_vec();
    out.extend_from_slice(&[0xFF, 0xE1]);
    out.extend_from_slice(&u16::try_from(segment.len() + 2).unwrap().to_be_bytes());
    out.extend_from_slice(&segment);
    out.extend_from_slice(&jpeg[2..]);
    out
}

pub(crate) struct Ready {
    pub(crate) media: Media,
    pub(crate) app: axum::Router,
    pub(crate) token: String,
    pub(crate) id: String,
    _guard: crate::support::TestDbGuard,
}

pub(crate) async fn ready(filename: &str, content: Vec<u8>) -> Ready {
    let (store, guard) = new_store().await;
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
    let media = Media::for_tests();
    let app = app_with_media(store.clone(), media.clone());
    let (token, _id) = register(&store, "alice").await;
    let uploaded = upload(&app, &token, filename, content).await;
    let id = uploaded["id"].as_str().unwrap().to_owned();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            serde_json::json!({
                "id": Uuid::now_v7().to_string(),
                "content": "a picture",
                "attachment_ids": [id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);
    Ready {
        media,
        app,
        token,
        id,
        _guard: guard,
    }
}

pub(crate) async fn fetch(
    ready: &Ready,
    query: &str,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let response = ready
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/attachments/{}{query}", ready.id))
                .header("authorization", format!("Bearer {}", ready.token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (parts, body) = response.into_parts();
    let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    (parts.status, parts.headers, bytes.to_vec())
}

/// Three decodes and encodes of a full-size photo in a debug build on a busy runner; the shared wait is sized for cheap effects.
const PREVIEW_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

#[tokio::test]
async fn a_large_photo_is_served_as_a_smaller_upright_preview_without_exif() {
    let original = with_orientation(&jpeg(&photo(2000, 1500), 92), 6);
    let r = ready("holiday.jpg", original.clone()).await;

    let (status, headers, body) = fetch(&r, "?w=640").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers[header::CONTENT_TYPE], "image/jpeg");
    assert!(
        headers[header::CACHE_CONTROL]
            .to_str()
            .unwrap()
            .contains("immutable")
    );
    assert!(
        body.len() * 4 < original.len(),
        "{} vs {}",
        body.len(),
        original.len()
    );
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (480, 640));
    assert!(!body.windows(4).any(|w| w == b"Exif"));
}

#[tokio::test]
async fn the_second_request_reuses_the_stored_preview() {
    let r = ready("a.jpg", jpeg(&photo(1800, 1200), 90)).await;

    let first = fetch(&r, "?w=640").await;
    let second = fetch(&r, "?w=640").await;

    assert_eq!(first.2, second.2);
    let (_, _, original) = fetch(&r, "").await;
    assert!(original.len() > first.2.len());
}

#[tokio::test]
async fn without_w_the_original_bytes_are_served() {
    let original = jpeg(&photo(1800, 1200), 90);
    let r = ready("a.jpg", original.clone()).await;

    let (status, _, body) = fetch(&r, "").await;

    assert_eq!((status, body), (StatusCode::OK, original));
}

#[tokio::test]
async fn a_small_picture_is_served_as_the_original() {
    let original = jpeg(&photo(200, 150), 85);
    let r = ready("tiny.jpg", original.clone()).await;

    let (_, _, body) = fetch(&r, "?w=640").await;

    assert_eq!(body, original);
}

#[tokio::test]
async fn an_animated_picture_is_served_as_the_original() {
    let r = ready("loop.gif", crate::support::images::animated_gif()).await;

    let (_, headers, body) = fetch(&r, "?w=640").await;

    assert_eq!(headers[header::CONTENT_TYPE], "image/gif");
    assert_eq!(body, crate::support::images::animated_gif());
}

#[tokio::test]
async fn a_picture_that_will_not_decode_falls_back_to_the_original() {
    let broken = crate::support::images::png(3000, 2000, &vec![7u8; 400_000]);
    let r = ready("broken.png", broken.clone()).await;

    let (status, _, body) = fetch(&r, "?w=640").await;

    assert_eq!((status, body), (StatusCode::OK, broken));
}

#[tokio::test]
async fn a_malformed_width_is_a_bad_request() {
    let r = ready("a.jpg", jpeg(&photo(1800, 1200), 90)).await;

    let (status, _, _) = fetch(&r, "?w=wide").await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_caller_who_cannot_view_the_attachment_gets_the_same_404_for_a_preview() {
    let r = ready("a.jpg", jpeg(&photo(1800, 1200), 90)).await;
    let missing = format!("/attachments/{}?w=640", "0".repeat(64));

    let response = r
        .app
        .clone()
        .oneshot(request_plain("GET", &missing, &r.token))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

fn mean_red(img: &image::DynamicImage) -> f64 {
    let rgb = img.to_rgb8();
    let total: u64 = rgb.pixels().map(|p| u64::from(p.0[0])).sum();
    total as f64 / f64::from(rgb.width() * rgb.height())
}

#[tokio::test]
async fn a_far_smaller_preview_keeps_the_picture_s_shape_and_brightness() {
    let source = photo(3000, 2000);
    let r = ready("big.jpg", jpeg(&source, 92)).await;

    let (_, _, body) = fetch(&r, "?w=320").await;

    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (320, 213));
    let expected = mean_red(&image::DynamicImage::ImageRgb8(source));
    assert!((mean_red(&decoded) - expected).abs() < 3.0);
}

#[tokio::test]
async fn an_upload_is_previewed_at_every_size_before_anyone_asks() {
    let r = ready("fresh.jpg", jpeg(&photo(2000, 1500), 92)).await;

    let all_three = crate::support::wait::holds_within_async(PREVIEW_BUDGET, || async {
        r.media.previews().files().await.unwrap().len() == 3
    })
    .await;
    assert!(
        all_three,
        "one preview file per size bucket never appeared within {PREVIEW_BUDGET:?}"
    );
}
