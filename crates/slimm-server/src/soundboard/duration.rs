// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reads a clip's length from its own bytes, without decoding any audio.
//! Bytes a decoder might play but this cannot count are refused, not skipped.

/// The length in milliseconds of an `audio/wav` or `audio/mpeg` clip, or None
/// when the bytes do not carry a length this can read.
pub fn of(bytes: &[u8], content_type: &str) -> Option<i64> {
    match content_type {
        "audio/wav" => wav(bytes),
        "audio/mpeg" => mp3(bytes),
        _ => None,
    }
}

fn le16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

fn le32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// The SubFormat GUID of WAVE_FORMAT_EXTENSIBLE after its first two bytes, which name the codec.
const SUBFORMAT_TAIL: [u8; 14] = [
    0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
];

/// The codec a `fmt ` body names: its format tag, or the SubFormat of an extensible one.
fn wav_codec(bytes: &[u8], body: usize, size: usize) -> Option<u16> {
    let format = le16(bytes, body)?;
    if format != 0xFFFE {
        return Some(format);
    }
    let extension = le16(bytes, body + 16)?;
    if size < 40 || extension < 22 || bytes.get(body + 26..body + 40)? != SUBFORMAT_TAIL {
        return None;
    }
    le16(bytes, body + 24)
}

/// The byte rate an uncompressed `fmt ` body implies, or None when it is
/// compressed, implausible, or its stated byte rate disagrees, since a forged
/// rate is how a long clip would pass for a short one.
fn pcm_byte_rate(bytes: &[u8], body: usize, size: usize) -> Option<u32> {
    if size < 16 {
        return None;
    }
    let codec = wav_codec(bytes, body, size)?;
    let channels = u32::from(le16(bytes, body + 2)?);
    let sample_rate = le32(bytes, body + 4)?;
    let stated = le32(bytes, body + 8)?;
    let bits = u32::from(le16(bytes, body + 14)?);
    let plausible = matches!(codec, 1 | 3)
        && (1..=8).contains(&channels)
        && (8_000..=192_000).contains(&sample_rate)
        && matches!(bits, 8 | 16 | 24 | 32);
    let derived = sample_rate * channels * bits / 8;
    (plausible && stated == derived).then_some(derived)
}

/// The RIFF chunk walk: byte rate from the one `fmt `, payload from every `data`.
fn wav(bytes: &[u8]) -> Option<i64> {
    let mut byte_rate = None;
    let mut payload: Option<usize> = None;
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let id = &bytes[at..at + 4];
        let size = le32(bytes, at + 4)? as usize;
        let body = at + 8;
        if id == b"fmt " {
            // Decoders read the first `fmt ` and ignore the rest, so a second one is refused.
            if byte_rate.is_some() {
                return None;
            }
            byte_rate = Some(pcm_byte_rate(bytes, body, size)?);
        } else if id == b"data" {
            // Audio before its format is something decoders refuse too.
            byte_rate?;
            // A streamed file may write 0xFFFFFFFF or a size past the end; the file's end is the truth.
            let length = size.min(bytes.len() - body);
            payload = Some(payload.unwrap_or(0) + length);
        }
        at = body.checked_add(size)?.checked_add(size & 1)?;
    }
    let rate = i64::from(byte_rate.filter(|rate| *rate > 0)?);
    Some(payload? as i64 * 1000 / rate)
}

const BITRATES_V1: [[u32; 15]; 3] = [
    [
        0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448,
    ],
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384,
    ],
    [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
    ],
];
const BITRATES_V2: [[u32; 15]; 2] = [
    [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256,
    ],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
];

/// Bytes after the last whole frame left uncounted: a cut-off frame of the largest size and an
/// ID3v1 tag. Even at the slowest bitrate that is under two seconds of sound.
const MAX_TAIL_BYTES: usize = 1441 + 128;

struct Frame {
    len: usize,
    samples: u32,
    sample_rate: u32,
}

/// A frame header's version, layer, bitrate index and sample rate index, or None when one is reserved.
fn header_fields(header: &[u8]) -> Option<(u8, u8, usize, usize)> {
    let [b0, b1, b2, _] = *<&[u8; 4]>::try_from(header.get(..4)?).ok()?;
    if b0 != 0xFF || b1 & 0xE0 != 0xE0 {
        return None;
    }
    let version = (b1 >> 3) & 3;
    let layer = 4 - ((b1 >> 1) & 3);
    let bitrate_index = usize::from(b2 >> 4);
    let rate_index = usize::from((b2 >> 2) & 3);
    let reserved = version == 1 || layer == 4 || bitrate_index == 15 || rate_index == 3;
    (!reserved).then_some((version, layer, bitrate_index, rate_index))
}

/// Whether these bytes start a free-format frame, whose length no header states.
fn is_free_format(header: &[u8]) -> bool {
    header_fields(header).is_some_and(|(_, _, bitrate_index, _)| bitrate_index == 0)
}

/// One MPEG audio frame header, or None if these four bytes are not one.
fn frame(header: &[u8]) -> Option<Frame> {
    let (version, layer, bitrate_index, rate_index) = header_fields(header)?;
    if bitrate_index == 0 {
        return None;
    }
    let mpeg1 = version == 3;
    let bitrate = 1000
        * if mpeg1 {
            BITRATES_V1[usize::from(layer) - 1][bitrate_index]
        } else {
            BITRATES_V2[usize::from(layer != 1)][bitrate_index]
        };
    let sample_rate = match version {
        3 => [44_100, 48_000, 32_000],
        2 => [22_050, 24_000, 16_000],
        _ => [11_025, 12_000, 8_000],
    }[rate_index];
    let padding = u32::from((header[2] >> 1) & 1);
    let (len, samples) = match layer {
        1 => ((12 * bitrate / sample_rate + padding) * 4, 384),
        2 => (144 * bitrate / sample_rate + padding, 1152),
        _ if mpeg1 => (144 * bitrate / sample_rate + padding, 1152),
        _ => (72 * bitrate / sample_rate + padding, 576),
    };
    Some(Frame {
        len: len as usize,
        samples,
        sample_rate,
    })
}

/// Where the audio starts: after any ID3v2 tags, or None when a tag's size is not synchsafe,
/// since a decoder would then not skip it and could play frames hidden inside.
fn after_id3v2(bytes: &[u8]) -> Option<usize> {
    let mut at = 0;
    while bytes.get(at..at + 3) == Some(b"ID3") {
        let header = bytes.get(at..at + 10)?;
        if header[6..10].iter().any(|b| b & 0x80 != 0) {
            return None;
        }
        let size = header[6..10]
            .iter()
            .fold(0usize, |acc, b| (acc << 7) | usize::from(*b));
        let footer = if header[5] & 0x10 != 0 { 10 } else { 0 };
        at += 10 + size + footer;
    }
    Some(at)
}

/// The whole frame starting at `at`, if one does.
fn frame_at(bytes: &[u8], at: usize) -> Option<Frame> {
    frame(bytes.get(at..)?).filter(|f| at + f.len <= bytes.len())
}

/// Sums one unbroken run of frames after any ID3v2 tags. Junk before the first frame is
/// skipped, a short tail after the last is allowed, and anything else is refused.
fn mp3(bytes: &[u8]) -> Option<i64> {
    let mut at = after_id3v2(bytes)?;
    while frame_at(bytes, at).is_none() {
        if at + 4 > bytes.len() || is_free_format(&bytes[at..]) {
            return None;
        }
        at += 1;
    }
    let mut micros: u64 = 0;
    while let Some(f) = frame_at(bytes, at) {
        micros += u64::from(f.samples) * 1_000_000 / u64::from(f.sample_rate);
        at += f.len;
    }
    let tail = &bytes[at..];
    let quiet =
        tail.len() <= MAX_TAIL_BYTES && !(0..tail.len()).any(|i| is_free_format(&tail[i..]));
    quiet.then_some((micros / 1000) as i64)
}

#[cfg(test)]
mod tests;
