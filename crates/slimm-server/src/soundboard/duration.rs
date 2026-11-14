// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reads a clip's length from its own bytes, without decoding any audio.

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

/// The byte rate an uncompressed `fmt ` body implies, or None when it is
/// compressed, implausible, or its stated byte rate disagrees, since a forged
/// rate is how a long clip would pass for a short one.
fn pcm_byte_rate(bytes: &[u8], body: usize) -> Option<u32> {
    let format = le16(bytes, body)?;
    let channels = u32::from(le16(bytes, body + 2)?);
    let sample_rate = le32(bytes, body + 4)?;
    let stated = le32(bytes, body + 8)?;
    let bits = u32::from(le16(bytes, body + 14)?);
    let plausible = matches!(format, 1 | 3 | 0xFFFE)
        && (1..=8).contains(&channels)
        && (8_000..=192_000).contains(&sample_rate)
        && matches!(bits, 8 | 16 | 24 | 32);
    let derived = sample_rate * channels * bits / 8;
    (plausible && stated == derived).then_some(derived)
}

/// The RIFF chunk walk: byte rate from `fmt `, payload size from `data`.
fn wav(bytes: &[u8]) -> Option<i64> {
    let mut byte_rate = None;
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let id = &bytes[at..at + 4];
        let size = le32(bytes, at + 4)? as usize;
        let body = at + 8;
        if id == b"fmt " {
            byte_rate = Some(pcm_byte_rate(bytes, body)?);
        } else if id == b"data" {
            let available = bytes.len() - body;
            // A streamed file may write 0xFFFFFFFF or a size past the end; the file's end is the truth.
            let length = size.min(available);
            let rate = i64::from(byte_rate.filter(|rate| *rate > 0)?);
            return Some(length as i64 * 1000 / rate);
        }
        at = body.checked_add(size)?.checked_add(size & 1)?;
    }
    None
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

struct Frame {
    len: usize,
    samples: u32,
    sample_rate: u32,
}

/// One MPEG audio frame header, or None if these four bytes are not one.
fn frame(header: &[u8]) -> Option<Frame> {
    let [b0, b1, b2, _] = *<&[u8; 4]>::try_from(header.get(..4)?).ok()?;
    if b0 != 0xFF || b1 & 0xE0 != 0xE0 {
        return None;
    }
    let version = (b1 >> 3) & 3;
    let layer = 4 - ((b1 >> 1) & 3);
    let bitrate_index = usize::from(b2 >> 4);
    let rate_index = usize::from((b2 >> 2) & 3);
    if version == 1 || layer == 4 || bitrate_index == 0 || bitrate_index == 15 || rate_index == 3 {
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
    let padding = u32::from((b2 >> 1) & 1);
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

/// Walks every frame after any ID3v2 tag and sums their samples.
fn mp3(bytes: &[u8]) -> Option<i64> {
    let mut at = 0;
    if bytes.starts_with(b"ID3") {
        let size = bytes
            .get(6..10)?
            .iter()
            .fold(0usize, |acc, b| (acc << 7) | usize::from(b & 0x7F));
        at = 10 + size;
    }
    let mut micros: u64 = 0;
    let mut frames = 0;
    while at + 4 <= bytes.len() {
        match frame(&bytes[at..]).filter(|f| at + f.len <= bytes.len()) {
            Some(f) => {
                micros += u64::from(f.samples) * 1_000_000 / u64::from(f.sample_rate);
                frames += 1;
                at += f.len;
            }
            None => at += 1,
        }
    }
    (frames > 0).then_some((micros / 1000) as i64)
}

#[cfg(test)]
mod tests;
