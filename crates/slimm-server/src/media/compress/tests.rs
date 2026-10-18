// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

use image::codecs::jpeg::JpegEncoder;
use image::{ExtendedColorType, ImageEncoder, RgbImage};

use super::*;

/// A little-endian TIFF block with a camera name, an orientation, an exposure
/// time and a GPS position whose rationals are easy to search for.
const GPS_RATIONALS: [u8; 24] = [
    52, 0, 0, 0, 1, 0, 0, 0, 31, 0, 0, 0, 1, 0, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0,
];

fn sample_exif(orientation: u16) -> Vec<u8> {
    fn entry(out: &mut Vec<u8>, tag: u16, kind: u16, count: u32, field: [u8; 4]) {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&kind.to_le_bytes());
        out.extend_from_slice(&count.to_le_bytes());
        out.extend_from_slice(&field);
    }
    let (ifd0_at, exif_at, gps_at, data_at) = (8u32, 62u32, 92u32, 122u32);
    let mut out = b"II*\0".to_vec();
    out.extend_from_slice(&ifd0_at.to_le_bytes());
    out.extend_from_slice(&4u16.to_le_bytes());
    entry(&mut out, 0x010F, 2, 11, data_at.to_le_bytes());
    entry(&mut out, 0x0112, 3, 1, [orientation as u8, 0, 0, 0]);
    entry(&mut out, 0x8769, 4, 1, exif_at.to_le_bytes());
    entry(&mut out, 0x8825, 4, 1, gps_at.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&2u16.to_le_bytes());
    entry(&mut out, 0x829A, 5, 1, (data_at + 12).to_le_bytes());
    entry(&mut out, 0xA002, 4, 1, 4000u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&2u16.to_le_bytes());
    entry(&mut out, 0x0001, 2, 2, [b'N', 0, 0, 0]);
    entry(&mut out, 0x0002, 5, 3, (data_at + 20).to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    assert_eq!(out.len(), data_at as usize);
    out.extend_from_slice(b"Pixelphone\0\0");
    out.extend_from_slice(&[1, 0, 0, 0, 250, 0, 0, 0]);
    out.extend_from_slice(&GPS_RATIONALS);
    out
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// A gradient with per-pixel noise, so it neither compresses to nothing nor looks drawn.
fn photo(width: u32, height: u32) -> RgbImage {
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

fn jpeg_with(img: &RgbImage, quality: u8, exif: Option<&[u8]>) -> Vec<u8> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .encode(
            img.as_raw(),
            img.width(),
            img.height(),
            ExtendedColorType::Rgb8,
        )
        .unwrap();
    let Some(exif) = exif else { return out };
    let mut with = out[..2].to_vec();
    jpeg_segments::push_app1(&mut with, exif);
    with.extend_from_slice(&out[2..]);
    with
}

fn policy(metadata: Metadata) -> Policy {
    Policy {
        extensions: DEFAULT_EXTENSIONS.iter().map(|e| (*e).to_owned()).collect(),
        metadata,
    }
}

fn run(bytes: &[u8], metadata: Metadata) -> Option<Compressed> {
    let p = policy(metadata);
    let kind = eligible_kind(bytes, &p)?;
    let candidate = inspect(kind, bytes)?;
    compress(candidate, bytes, &p, &DEFAULT_SETTINGS)
}

#[test]
fn orientation_and_location_are_read_from_a_block() {
    let exif = sample_exif(6);
    assert_eq!(exif::orientation(&exif), Some(6));
    assert!(exif::has_location(&exif));
}

#[test]
fn a_rebuilt_block_keeps_the_camera_and_leaves_no_position_bytes() {
    let rebuilt = exif::without_location(
        &sample_exif(6),
        exif::Rewrite {
            orientation: Some(1),
            dimensions: Some((1024, 768)),
        },
    )
    .unwrap();
    assert_eq!(exif::orientation(&rebuilt), Some(1));
    assert!(!exif::has_location(&rebuilt));
    assert!(contains(&rebuilt, b"Pixelphone"));
    assert!(!contains(&rebuilt, &GPS_RATIONALS));
}

#[test]
fn patching_in_place_resets_the_orientation_and_keeps_the_position() {
    let patched = exif::patched(
        &sample_exif(8),
        exif::Rewrite {
            orientation: Some(1),
            dimensions: None,
        },
    );
    assert_eq!(exif::orientation(&patched), Some(1));
    assert!(contains(&patched, &GPS_RATIONALS));
}

#[test]
fn stripping_a_jpeg_changes_no_pixel_and_removes_the_position() {
    let source = jpeg_with(&photo(96, 64), 90, Some(&sample_exif(6)));
    let stripped = jpeg_segments::strip(&source, Metadata::RemoveLocation).unwrap();
    assert!(!contains(&stripped, &GPS_RATIONALS));
    let exif = jpeg_segments::exif_of(&stripped).unwrap();
    assert_eq!(exif::orientation(&exif), Some(6));
    let before = image::load_from_memory(&source).unwrap().to_rgb8();
    let after = image::load_from_memory(&stripped).unwrap().to_rgb8();
    assert_eq!(before.as_raw(), after.as_raw());
}

#[test]
fn removing_everything_keeps_only_an_orientation() {
    let source = jpeg_with(&photo(96, 64), 90, Some(&sample_exif(3)));
    let stripped = jpeg_segments::strip(&source, Metadata::RemoveAll).unwrap();
    let exif = jpeg_segments::exif_of(&stripped).unwrap();
    assert_eq!(exif::orientation(&exif), Some(3));
    assert!(!contains(&stripped, b"Pixelphone"));
}

#[test]
fn a_jpeg_without_the_metadata_is_left_as_it_is() {
    let source = jpeg_with(&photo(96, 64), 90, None);
    assert!(jpeg_segments::strip(&source, Metadata::RemoveAll).is_none());
    assert!(jpeg_segments::strip(&source, Metadata::Keep).is_none());
}

#[test]
fn a_large_photo_gets_smaller_upright_and_without_its_position() {
    let source = jpeg_with(&photo(640, 480), 98, Some(&sample_exif(6)));
    let out = run(&source, Metadata::RemoveLocation).expect("a q98 noisy photo shrinks");
    assert_eq!(out.content_type, "image/jpeg");
    assert!(out.bytes.len() * 100 < source.len() * 90);
    let decoded = image::load_from_memory(&out.bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (480, 640));
    assert!(!contains(&out.bytes, &GPS_RATIONALS));
    let kept = jpeg_segments::exif_of(&out.bytes).unwrap();
    assert_eq!(exif::orientation(&kept), Some(1));
}

#[test]
fn keeping_all_metadata_keeps_the_position() {
    let source = jpeg_with(&photo(640, 480), 98, Some(&sample_exif(1)));
    let out = run(&source, Metadata::Keep).unwrap();
    assert!(contains(&out.bytes, &GPS_RATIONALS));
}

#[test]
fn removing_all_metadata_leaves_no_exif_segment() {
    let source = jpeg_with(&photo(640, 480), 98, Some(&sample_exif(6)));
    let out = run(&source, Metadata::RemoveAll).unwrap();
    assert!(jpeg_segments::exif_of(&out.bytes).is_none());
}

#[test]
fn an_oversized_photo_is_scaled_to_the_long_edge() {
    let source = jpeg_with(&photo(640, 480), 98, None);
    let p = policy(Metadata::RemoveAll);
    let candidate = inspect(Kind::Jpeg, &source).unwrap();
    let small = Settings {
        long_edge: 320,
        ..DEFAULT_SETTINGS
    };
    let out = compress(candidate, &source, &p, &small).unwrap();
    let decoded = image::load_from_memory(&out.bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (320, 240));
}

#[test]
fn an_already_small_jpeg_is_stored_as_sent() {
    let source = jpeg_with(&photo(160, 120), 50, None);
    assert!(run(&source, Metadata::RemoveAll).is_none());
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

fn png_bytes(img: &RgbImage) -> Vec<u8> {
    let mut out = Vec::new();
    image::codecs::png::PngEncoder::new_with_quality(
        &mut out,
        image::codecs::png::CompressionType::Fast,
        image::codecs::png::FilterType::NoFilter,
    )
    .write_image_x(img);
    out
}

trait WriteImageX {
    fn write_image_x(self, img: &RgbImage);
}

impl<T: image::ImageEncoder> WriteImageX for T {
    fn write_image_x(self, img: &RgbImage) {
        self.write_image(
            img.as_raw(),
            img.width(),
            img.height(),
            ExtendedColorType::Rgb8,
        )
        .unwrap();
    }
}

#[test]
fn a_screenshot_stays_pixel_identical() {
    let img = screenshot();
    let source = png_bytes(&img);
    let out = run(&source, Metadata::RemoveAll).expect("an unoptimised png shrinks losslessly");
    assert_eq!(out.content_type, "image/png");
    assert!(out.bytes.len() < source.len());
    let decoded = image::load_from_memory(&out.bytes).unwrap().to_rgb8();
    assert_eq!(decoded.as_raw(), img.as_raw());
}

#[test]
fn a_photo_saved_as_png_becomes_a_jpeg() {
    let source = png_bytes(&photo(320, 240));
    let out = run(&source, Metadata::RemoveAll).unwrap();
    assert_eq!(out.content_type, "image/jpeg");
    assert_eq!(out.extension, "jpg");
}

#[test]
fn a_transparent_png_keeps_its_transparency() {
    let img =
        image::RgbaImage::from_fn(300, 200, |x, _| image::Rgba([10, 10, 10, (x % 256) as u8]));
    let mut source = Vec::new();
    image::codecs::png::PngEncoder::new_with_quality(
        &mut source,
        image::codecs::png::CompressionType::Fast,
        image::codecs::png::FilterType::NoFilter,
    )
    .write_image(img.as_raw(), 300, 200, ExtendedColorType::Rgba8)
    .unwrap();
    let out = run(&source, Metadata::RemoveAll).unwrap();
    assert_eq!(out.content_type, "image/png");
    let decoded = image::load_from_memory(&out.bytes).unwrap().to_rgba8();
    assert_eq!(decoded.as_raw(), img.as_raw());
}

#[test]
fn a_heic_becomes_a_jpeg_every_client_draws() {
    let source = include_bytes!("../../../tests/attachments/tiny.heic");
    let out = run(source, Metadata::RemoveAll).expect("the fixture decodes");
    assert_eq!(out.content_type, "image/jpeg");
    let decoded = image::load_from_memory(&out.bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (160, 112));
}

#[test]
fn only_listed_extensions_make_a_format_eligible() {
    let jpeg = jpeg_with(&photo(32, 32), 90, None);
    let mut only_png = policy(Metadata::Keep);
    only_png.extensions = vec!["png".to_owned()];
    assert!(eligible_kind(&jpeg, &only_png).is_none());
    only_png.extensions.push("jpe".to_owned());
    assert_eq!(eligible_kind(&jpeg, &only_png), Some(Kind::Jpeg));
}

#[test]
fn animated_and_unknown_files_are_never_candidates() {
    let gif =
        b"GIF89a\x01\0\x01\0\x80\0\0\0\0\0\xff\xff\xff,\0\0\0\0\x01\0\x01\0\0\x02\x02D\x01\0;";
    assert!(eligible_kind(gif, &policy(Metadata::Keep)).is_none());
    assert!(
        eligible_kind(
            b"\0\0\0\x18ftypmp42\0\0\0\0mp42isom",
            &policy(Metadata::Keep)
        )
        .is_none()
    );
    let mut apng = png_bytes(&screenshot());
    let at = apng.windows(4).position(|w| w == b"IDAT").unwrap() - 4;
    let mut actl = 8u32.to_be_bytes().to_vec();
    actl.extend_from_slice(b"acTL\0\0\0\x02\0\0\0\0\0\0\0\0");
    apng.splice(at..at, actl);
    assert!(inspect(Kind::Png, &apng).is_none());
}

#[test]
fn extension_lists_are_normalised_and_checked() {
    let raw = ["JPG".to_owned(), ".png".to_owned(), "jpg".to_owned()];
    assert_eq!(normalize_extensions(&raw).unwrap(), vec!["jpg", "png"]);
    assert_eq!(
        normalize_extensions(&["gif".to_owned()]),
        Err(ExtensionError::Unsupported("gif".to_owned()))
    );
    assert!(matches!(
        normalize_extensions(&["j p".to_owned()]),
        Err(ExtensionError::Malformed(_))
    ));
}

#[test]
fn a_drawing_is_told_from_a_photo() {
    assert!(classify::is_graphic(&image::DynamicImage::ImageRgb8(
        screenshot()
    )));
    assert!(!classify::is_graphic(&image::DynamicImage::ImageRgb8(
        photo(300, 200)
    )));
}
