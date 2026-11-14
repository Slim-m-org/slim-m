// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

/// A PCM wav of `data_len` bytes at 8000 Hz, mono, 16-bit (16000 bytes a second).
pub(crate) fn wav_bytes(data_len: usize) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&8000u32.to_le_bytes());
    out.extend_from_slice(&16_000u32.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    out.extend(std::iter::repeat_n(0u8, data_len));
    out
}

/// `frames` MPEG-1 layer III frames at 128 kbps and 44.1 kHz (417 bytes, 26.12 ms each).
pub(crate) fn mp3_bytes(frames: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for _ in 0..frames {
        out.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x00]);
        out.extend(std::iter::repeat_n(0u8, 413));
    }
    out
}

#[test]
fn a_wav_length_comes_from_its_byte_rate() {
    assert_eq!(of(&wav_bytes(16_000), "audio/wav"), Some(1000));
    assert_eq!(of(&wav_bytes(40_000), "audio/wav"), Some(2500));
}

#[test]
fn a_wav_claiming_more_data_than_it_holds_is_measured_by_what_it_holds() {
    let mut bytes = wav_bytes(16_000);
    bytes[40..44].copy_from_slice(&u32::MAX.to_le_bytes());
    assert_eq!(of(&bytes, "audio/wav"), Some(1000));
}

#[test]
fn a_wav_whose_byte_rate_disagrees_with_its_format_has_no_length() {
    let mut bytes = wav_bytes(16_000);
    bytes[28..32].copy_from_slice(&u32::MAX.to_le_bytes());
    assert_eq!(of(&bytes, "audio/wav"), None);
}

#[test]
fn a_compressed_wav_has_no_length() {
    let mut bytes = wav_bytes(16_000);
    bytes[20..22].copy_from_slice(&2u16.to_le_bytes());
    assert_eq!(of(&bytes, "audio/wav"), None);
}

#[test]
fn a_wav_without_a_data_chunk_has_no_length() {
    assert_eq!(of(&wav_bytes(16_000)[..36], "audio/wav"), None);
}

#[test]
fn an_mp3_length_is_the_sum_of_its_frames() {
    let ms = of(&mp3_bytes(100), "audio/mpeg").unwrap();
    assert!((2610..=2613).contains(&ms), "{ms}");
}

#[test]
fn an_id3_tag_is_skipped_and_trailing_junk_is_ignored() {
    let mut bytes = b"ID3\x04\x00\x00\x00\x00\x00\x05hello".to_vec();
    bytes.extend(mp3_bytes(10));
    bytes.extend_from_slice(b"TAG-not-a-frame");
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((260..=262).contains(&ms), "{ms}");
}

#[test]
fn bytes_with_no_frame_have_no_length() {
    assert_eq!(of(&[0u8; 2000], "audio/mpeg"), None);
}
