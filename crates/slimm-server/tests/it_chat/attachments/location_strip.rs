// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A photo's location never reaches a viewer, whether or not compression ran,
//! produced anything, or kept the original.

use axum::http::{StatusCode, header};
use image::{ExtendedColorType, ImageEncoder};
use serde_json::json;
use std::time::Duration;

use slimm_server::media::{Media, MemoryBudget};

use super::compression::{
    GPS_RATIONALS, MIB, configure, contains, exif_with_position, fetch, phone_photo, png_of,
    screenshot, space, space_with, upload_as,
};

fn webp_with_position() -> Vec<u8> {
    let img = screenshot();
    let mut lossless = Vec::new();
    image::codecs::webp::WebPEncoder::new_lossless(&mut lossless)
        .write_image(img.as_raw(), 400, 300, ExtendedColorType::Rgb8)
        .unwrap();
    let image_chunks = &lossless[12..];
    let mut flags_and_canvas = vec![0x08, 0, 0, 0];
    flags_and_canvas.extend_from_slice(&399u32.to_le_bytes()[..3]);
    flags_and_canvas.extend_from_slice(&299u32.to_le_bytes()[..3]);
    let mut body = b"WEBP".to_vec();
    push_riff(&mut body, b"VP8X", &flags_and_canvas);
    body.extend_from_slice(image_chunks);
    push_riff(&mut body, b"EXIF", &exif_with_position(6));
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&u32::try_from(body.len()).unwrap().to_le_bytes());
    out.extend_from_slice(&body);
    out
}

fn push_riff(out: &mut Vec<u8>, name: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(name);
    out.extend_from_slice(&u32::try_from(data.len()).unwrap().to_le_bytes());
    out.extend_from_slice(data);
    if data.len() % 2 == 1 {
        out.push(0);
    }
}

fn png_with_position() -> Vec<u8> {
    let png = png_of(&screenshot());
    let exif = exif_with_position(6);
    let mut out = png[..33].to_vec();
    out.extend_from_slice(&u32::try_from(exif.len()).unwrap().to_be_bytes());
    out.extend_from_slice(b"eXIf");
    out.extend_from_slice(&exif);
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&png[33..]);
    out
}

#[tokio::test]
async fn a_jpeg_is_served_without_its_position_when_compression_is_off() {
    let space = space().await;
    let photo = phone_photo();
    let stored = upload_as(&space, "IMG_0001.jpg", photo.clone()).await;
    let (status, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert_eq!(status, StatusCode::OK);
    assert!(!contains(&body, &GPS_RATIONALS));
    assert!(contains(&body, b"Exif\0\0"), "the orientation stays");
    assert_eq!(stored["size"], json!(body.len()));
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (640, 480));
}

#[tokio::test]
async fn a_webp_is_served_without_its_position() {
    let space = space().await;
    let photo = webp_with_position();
    assert!(contains(&photo, &GPS_RATIONALS));
    let stored = upload_as(&space, "IMG_0001.webp", photo).await;
    let (_, headers, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert_eq!(headers[header::CONTENT_TYPE], "image/webp");
    assert!(!contains(&body, &GPS_RATIONALS));
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (400, 300));
}

#[tokio::test]
async fn a_png_is_served_without_its_position() {
    let space = space().await;
    let photo = png_with_position();
    assert!(contains(&photo, &GPS_RATIONALS));
    let stored = upload_as(&space, "IMG_0001.png", photo).await;
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert!(!contains(&body, &GPS_RATIONALS));
    assert!(image::load_from_memory(&body).is_ok());
}

#[tokio::test]
async fn a_webp_that_compression_leaves_alone_is_still_stripped() {
    let space = space().await;
    configure(&space, json!({"enabled": true})).await;
    let stored = upload_as(&space, "IMG_0001.webp", webp_with_position()).await;
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert!(!contains(&body, &GPS_RATIONALS));
}

#[tokio::test]
async fn the_kept_original_carries_no_position_either() {
    let space = space().await;
    configure(&space, json!({"enabled": true, "keep_original": true})).await;
    let stored = upload_as(&space, "IMG_0001.jpg", phone_photo()).await;
    let id = stored["id"].as_str().unwrap();
    let (status, _, original) = fetch(&space, id, "?original=true").await;
    assert_eq!(status, StatusCode::OK);
    assert!(!contains(&original, &GPS_RATIONALS));
    assert_eq!(stored["original"]["size"], json!(original.len()));
    let decoded = image::load_from_memory(&original).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (640, 480));
}

#[tokio::test]
async fn a_photo_the_memory_budget_refuses_is_stripped_not_decoded() {
    let tiny = MemoryBudget::new(8 * MIB, Duration::from_millis(50));
    let space = space_with(Media::for_tests().with_memory_budget(tiny)).await;
    configure(&space, json!({"enabled": true})).await;
    let stored = upload_as(&space, "IMG_0001.jpg", phone_photo()).await;
    let (_, _, body) = fetch(&space, stored["id"].as_str().unwrap(), "").await;
    assert!(!contains(&body, &GPS_RATIONALS));
}
