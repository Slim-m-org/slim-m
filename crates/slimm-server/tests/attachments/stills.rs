// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /attachments/{id}?w=N` on a picture that moves answers its first frame,
//! and on a photograph too big to decode whole answers a reduced-scale decode.

use axum::http::{StatusCode, header};
use image::codecs::gif::{GifEncoder, Repeat};
use image::codecs::webp::WebPEncoder;
use image::{ExtendedColorType, Frame, RgbImage, RgbaImage};

use super::previews::{fetch, jpeg, photo, ready};

fn animated_gif(width: u32, height: u32) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut encoder = GifEncoder::new(&mut out);
        encoder.set_repeat(Repeat::Infinite).unwrap();
        for shift in [0u32, 40] {
            let frame = RgbaImage::from_fn(width, height, |x, y| {
                let v = ((x + shift) * 255 / width) as u8;
                image::Rgba([v, (y * 255 / height) as u8, 90, 255])
            });
            encoder.encode_frame(Frame::new(frame)).unwrap();
        }
    }
    out
}

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = kind.to_vec();
    out.extend_from_slice(&u32::try_from(data.len()).unwrap().to_le_bytes());
    out.extend_from_slice(data);
    if data.len() % 2 == 1 {
        out.push(0);
    }
    out
}

/// An animated WebP of one lossless frame, enough for the header to say it animates.
fn animated_webp(width: u32, height: u32) -> Vec<u8> {
    let raster = RgbaImage::from_fn(width, height, |x, y| {
        image::Rgba([(x % 251) as u8, (y % 241) as u8, ((x * y) % 239) as u8, 255])
    });
    let mut still = Vec::new();
    WebPEncoder::new_lossless(&mut still)
        .encode(raster.as_raw(), width, height, ExtendedColorType::Rgba8)
        .unwrap();
    let frame_chunk = &still[12..];
    let mut vp8x = vec![0x02, 0, 0, 0];
    vp8x.extend_from_slice(&(width - 1).to_le_bytes()[..3]);
    vp8x.extend_from_slice(&(height - 1).to_le_bytes()[..3]);
    let mut anmf = vec![0u8; 6];
    anmf.extend_from_slice(&(width - 1).to_le_bytes()[..3]);
    anmf.extend_from_slice(&(height - 1).to_le_bytes()[..3]);
    anmf.extend_from_slice(&[100, 0, 0, 0]);
    anmf.extend_from_slice(frame_chunk);
    let mut body = b"WEBP".to_vec();
    body.extend(chunk(b"VP8X", &vp8x));
    body.extend(chunk(b"ANIM", &[0; 6]));
    body.extend(chunk(b"ANMF", &anmf));
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&u32::try_from(body.len()).unwrap().to_le_bytes());
    out.extend(body);
    out
}

#[tokio::test]
async fn a_gif_preview_is_its_first_frame_as_a_smaller_still() {
    let original = animated_gif(900, 600);
    let r = ready("loop.gif", original.clone()).await;

    let (status, headers, body) = fetch(&r, "?w=320").await;

    assert_eq!(status, StatusCode::OK);
    assert_ne!(headers[header::CONTENT_TYPE], "image/gif");
    assert!(
        body.len() < original.len(),
        "{} vs {}",
        body.len(),
        original.len()
    );
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (320, 213));
}

#[tokio::test]
async fn a_gif_without_w_is_still_the_moving_original() {
    let original = animated_gif(900, 600);
    let r = ready("loop.gif", original.clone()).await;

    let (_, headers, body) = fetch(&r, "").await;

    assert_eq!(headers[header::CONTENT_TYPE], "image/gif");
    assert_eq!(body, original);
}

#[tokio::test]
async fn an_uploaded_gif_is_given_its_stills_before_anyone_asks() {
    let r = ready("loop.gif", animated_gif(900, 600)).await;

    crate::support::wait::wait_until_async("one still per size bucket", || async {
        r.media.previews().files().await.unwrap().len() == 3
    })
    .await;
}

#[tokio::test]
async fn an_animated_webp_keeps_moving_unless_a_still_is_asked_for() {
    let original = animated_webp(900, 600);
    let r = ready("loop.webp", original.clone()).await;

    let (_, _, plain) = fetch(&r, "?w=320").await;
    let (_, _, still) = fetch(&r, "?w=320&still=true").await;

    assert_eq!(plain, original);
    assert_ne!(still, original);
    let decoded = image::load_from_memory(&still).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (320, 213));
}

#[tokio::test]
async fn asking_for_a_still_of_a_picture_that_does_not_move_is_the_ordinary_preview() {
    let r = ready("a.jpg", jpeg(&photo(1800, 1200), 90)).await;

    let (_, _, plain) = fetch(&r, "?w=320").await;
    let (_, _, still) = fetch(&r, "?w=320&still=true").await;

    assert_eq!(plain, still);
}

fn gradient(width: u32, height: u32) -> RgbImage {
    RgbImage::from_fn(width, height, |x, y| {
        image::Rgb([(x / 26) as u8, (y / 25) as u8, ((x + y) / 51) as u8])
    })
}

#[tokio::test]
async fn a_photo_over_forty_megapixels_still_gets_a_real_preview() {
    let original = jpeg(&gradient(6500, 6200), 90);
    let r = ready("huge.jpg", original.clone()).await;

    let (status, _, body) = fetch(&r, "?w=640").await;

    assert_eq!(status, StatusCode::OK);
    assert!(
        body.len() * 10 < original.len(),
        "{} vs {}",
        body.len(),
        original.len()
    );
    let decoded = image::load_from_memory(&body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (640, 610));
}
