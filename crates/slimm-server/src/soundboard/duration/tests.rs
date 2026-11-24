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

/// A RIFF/WAVE file made of `chunks`, each padded to an even length.
fn riff(chunks: &[(&[u8; 4], Vec<u8>)]) -> Vec<u8> {
    let mut body = b"WAVE".to_vec();
    for (id, payload) in chunks {
        body.extend_from_slice(*id);
        body.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        body.extend_from_slice(payload);
        if payload.len() % 2 == 1 {
            body.push(0);
        }
    }
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend(body);
    out
}

/// A 16-byte `fmt ` body whose byte rate agrees with its format.
fn fmt_body(format: u16, channels: u16, rate: u32, bits: u16) -> Vec<u8> {
    let mut out = format.to_le_bytes().to_vec();
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    let byte_rate = rate
        .wrapping_mul(u32::from(channels))
        .wrapping_mul(u32::from(bits))
        / 8;
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&(channels.wrapping_mul(bits) / 8).to_le_bytes());
    out.extend_from_slice(&bits.to_le_bytes());
    out
}

/// A WAVE_FORMAT_EXTENSIBLE `fmt ` body for 8 kHz mono 16-bit whose SubFormat GUID starts with `codec`.
fn extensible_body(codec: u16) -> Vec<u8> {
    let mut out = fmt_body(0xFFFE, 1, 8000, 16);
    out.extend_from_slice(&22u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(&4u32.to_le_bytes());
    out.extend_from_slice(&u32::from(codec).to_le_bytes());
    out.extend_from_slice(&[
        0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ]);
    out
}

#[test]
fn a_wav_with_two_fmt_chunks_has_no_length() {
    let bytes = riff(&[
        (b"fmt ", fmt_body(1, 1, 8000, 8)),
        (b"fmt ", fmt_body(1, 8, 192_000, 32)),
        (b"data", vec![0x80; 400_000]),
    ]);
    assert_eq!(of(&bytes, "audio/wav"), None);
}

#[test]
fn a_wav_whose_audio_comes_in_two_data_chunks_is_measured_by_both() {
    let bytes = riff(&[
        (b"fmt ", fmt_body(1, 1, 8000, 16)),
        (b"data", vec![0; 16_000]),
        (b"data", vec![0; 32_000]),
    ]);
    assert_eq!(of(&bytes, "audio/wav"), Some(3000));
}

#[test]
fn a_fmt_chunk_too_short_for_its_fields_has_no_length() {
    let mut short = fmt_body(1, 1, 8000, 8);
    short.truncate(14);
    let bytes = riff(&[
        (b"fmt ", short),
        (&[8, 0, b'x', b'x'], Vec::new()),
        (b"data", vec![0x80; 16_000]),
    ]);
    assert_eq!(of(&bytes, "audio/wav"), None);
}

#[test]
fn an_extensible_wav_is_measured_only_when_its_subformat_is_uncompressed() {
    let pcm = riff(&[(b"fmt ", extensible_body(1)), (b"data", vec![0; 16_000])]);
    assert_eq!(of(&pcm, "audio/wav"), Some(1000));
    let adpcm = riff(&[(b"fmt ", extensible_body(0x11)), (b"data", vec![0; 16_000])]);
    assert_eq!(of(&adpcm, "audio/wav"), None);
    let mut bare = fmt_body(0xFFFE, 1, 8000, 16);
    bare.extend_from_slice(&0u16.to_le_bytes());
    assert_eq!(
        of(
            &riff(&[(b"fmt ", bare), (b"data", vec![0; 16_000])]),
            "audio/wav"
        ),
        None,
        "an extensible header with no SubFormat"
    );
}

#[test]
fn a_free_format_mp3_has_no_length() {
    let mut bytes = mp3_bytes(100);
    for frame in bytes.chunks_mut(417).skip(1) {
        frame[2] &= 0x0F;
    }
    assert_eq!(of(&bytes, "audio/mpeg"), None);
}

#[test]
fn junk_between_mp3_frames_has_no_length() {
    let mut bytes = mp3_bytes(10);
    bytes.extend(std::iter::repeat_n(0u8, 4096));
    bytes.extend(mp3_bytes(10));
    assert_eq!(of(&bytes, "audio/mpeg"), None);
}

#[test]
fn an_id3_tag_whose_size_is_not_synchsafe_has_no_length() {
    // Read with the top bits masked off, this size would hide all but the last few frames.
    let mut bytes = b"ID3\x04\x00\x00\x00\x18\xff\xff".to_vec();
    bytes.extend(mp3_bytes(1000));
    assert_eq!(of(&bytes, "audio/mpeg"), None);
}

#[test]
fn an_id3v1_tag_after_the_frames_is_ignored() {
    let mut bytes = mp3_bytes(10);
    bytes.extend_from_slice(b"TAG");
    bytes.extend(std::iter::repeat_n(b' ', 125));
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((260..=262).contains(&ms), "{ms}");
}

/// `frames` MPEG-1 layer II frames at 384 kbps and 32 kHz, the largest any header states.
fn layer2_bytes(frames: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for _ in 0..frames {
        out.extend_from_slice(&[0xFF, 0xFD, 0xE8, 0x00]);
        out.extend(std::iter::repeat_n(0u8, 1724));
    }
    out
}

/// An APEv2 tag with a header and footer around `items`.
fn ape_tag(items: &[u8]) -> Vec<u8> {
    let mark = |flags: u32| {
        let mut out = b"APETAGEX".to_vec();
        out.extend_from_slice(&2000u32.to_le_bytes());
        out.extend_from_slice(&(items.len() as u32 + 32).to_le_bytes());
        out.extend_from_slice(&1u32.to_le_bytes());
        out.extend_from_slice(&flags.to_le_bytes());
        out.extend_from_slice(&[0; 8]);
        out
    };
    let mut out = mark(0xA000_0000);
    out.extend_from_slice(items);
    out.extend(mark(0x8000_0000));
    out
}

fn id3v1() -> Vec<u8> {
    let mut out = b"TAG".to_vec();
    out.extend(std::iter::repeat_n(b' ', 125));
    out
}

#[test]
fn a_cut_off_layer_ii_frame_of_the_largest_size_is_allowed() {
    let mut bytes = layer2_bytes(20);
    bytes.extend_from_slice(&layer2_bytes(1)[..1700]);
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((719..=721).contains(&ms), "{ms}");
}

#[test]
fn trailing_ape_and_lyrics3_tags_are_skipped_by_their_stated_size() {
    let mut items = Vec::new();
    items.extend_from_slice(&4000u32.to_le_bytes());
    items.extend_from_slice(&0u32.to_le_bytes());
    items.extend_from_slice(b"REPLAYGAIN_TRACK_GAIN\0");
    items.extend_from_slice(&[0xFF, 0xFB, 0x00, 0x00]);
    items.extend(std::iter::repeat_n(b'x', 3996));
    let mut bytes = mp3_bytes(10);
    bytes.extend(ape_tag(&items));
    bytes.extend_from_slice(b"LYRICSBEGININD0000211");
    bytes.extend_from_slice(b"000021LYRICS200");
    bytes.extend(id3v1());
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((260..=262).contains(&ms), "{ms}");
}

#[test]
fn a_lyrics3_v1_tag_is_skipped() {
    let mut bytes = mp3_bytes(10);
    bytes.extend_from_slice(b"LYRICSBEGIN");
    bytes.extend(std::iter::repeat_n(b'l', 3000));
    bytes.extend_from_slice(b"LYRICSEND");
    bytes.extend(id3v1());
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((260..=262).contains(&ms), "{ms}");
}

/// A decoder that ignores tags would play these frames, so they count.
#[test]
fn frames_inside_a_trailing_tag_still_count() {
    let mut bytes = mp3_bytes(10);
    bytes.extend(ape_tag(&mp3_bytes(300)));
    let ms = of(&bytes, "audio/mpeg").unwrap();
    assert!((8095..=8100).contains(&ms), "{ms}");
}

#[test]
fn a_wav_with_overflowing_format_fields_is_refused_without_panic() {
    let bytes = riff(&[
        (b"fmt ", fmt_body(1, u16::MAX, u32::MAX, u16::MAX)),
        (b"data", vec![0; 16_000]),
    ]);
    assert_eq!(of(&bytes, "audio/wav"), None);
}
