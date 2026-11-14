// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turns a stored voice message, WAV or Ogg/Opus, into the 16 kHz mono samples
//! the speech engine takes. Everything is held in memory; nothing is written.

use std::io::Cursor;

use anyhow::{Context, bail};
use opus::{Channels, Decoder};

use crate::endpoint::SAMPLE_RATE;

/// The longest clip decoded, a little over the client's 5 minute cap.
pub const MAX_CLIP_SECONDS: usize = 6 * 60;

const OPUS_MAX_FRAME_MS: usize = 120;

/// Decodes `bytes` by what they start with, never by a declared type.
pub fn decode(bytes: &[u8]) -> anyhow::Result<Vec<i16>> {
    let samples = if bytes.starts_with(b"RIFF") {
        wav(bytes)?
    } else if bytes.starts_with(b"OggS") {
        ogg_opus(bytes)?
    } else {
        bail!("not a WAV or Ogg Opus file");
    };
    if samples.len() > MAX_CLIP_SECONDS * SAMPLE_RATE {
        bail!("the clip is longer than {MAX_CLIP_SECONDS} seconds");
    }
    Ok(samples)
}

fn wav(bytes: &[u8]) -> anyhow::Result<Vec<i16>> {
    if bytes.len() < 12 || &bytes[8..12] != b"WAVE" {
        bail!("not a WAV file");
    }
    let (mut channels, mut rate, mut data) = (0_usize, 0_usize, None);
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into()?) as usize;
        let body = &bytes[at + 8..bytes.len().min(at + 8 + size)];
        match &bytes[at..at + 4] {
            b"fmt " if body.len() >= 16 => {
                let format = u16::from_le_bytes(body[0..2].try_into()?);
                let bits = u16::from_le_bytes(body[14..16].try_into()?);
                if format != 1 || bits != 16 {
                    bail!("only 16 bit PCM WAV is supported");
                }
                channels = usize::from(u16::from_le_bytes(body[2..4].try_into()?));
                rate = u32::from_le_bytes(body[4..8].try_into()?) as usize;
            }
            b"data" => data = Some(body),
            _ => {}
        }
        at += 8 + size + (size & 1);
    }
    let data = data.context("the WAV has no audio")?;
    if channels == 0 || rate == 0 {
        bail!("the WAV has no format");
    }
    let interleaved: Vec<i16> = data
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    Ok(resample(&mono(&interleaved, channels), rate))
}

fn mono(interleaved: &[i16], channels: usize) -> Vec<i16> {
    interleaved
        .chunks_exact(channels)
        .map(|frame| {
            let sum: i32 = frame.iter().map(|s| i32::from(*s)).sum();
            (sum / channels as i32) as i16
        })
        .collect()
}

/// Linear interpolation to 16 kHz, enough for speech going into a recogniser.
fn resample(samples: &[i16], rate: usize) -> Vec<i16> {
    if rate == SAMPLE_RATE || samples.is_empty() {
        return samples.to_vec();
    }
    let out_len = samples.len() * SAMPLE_RATE / rate;
    (0..out_len)
        .map(|i| {
            let at = i as f64 * rate as f64 / SAMPLE_RATE as f64;
            let low = at.floor() as usize;
            let high = (low + 1).min(samples.len() - 1);
            let frac = at - low as f64;
            (f64::from(samples[low]) * (1.0 - frac) + f64::from(samples[high]) * frac).round()
                as i16
        })
        .collect()
}

fn ogg_opus(bytes: &[u8]) -> anyhow::Result<Vec<i16>> {
    let mut packets = ogg::reading::PacketReader::new(Cursor::new(bytes));
    let head = packets
        .read_packet()?
        .context("the Ogg file is empty")?
        .data;
    if head.len() < 19 || !head.starts_with(b"OpusHead") {
        bail!("the Ogg file is not Opus");
    }
    let channels = match head[9] {
        1 => Channels::Mono,
        2 => Channels::Stereo,
        other => bail!("{other} Opus channels are not supported"),
    };
    let count = usize::from(head[9]);
    let pre_skip = usize::from(u16::from_le_bytes([head[10], head[11]])) * SAMPLE_RATE / 48_000;
    let mut decoder = Decoder::new(SAMPLE_RATE as u32, channels)?;
    let mut frame = vec![0_i16; SAMPLE_RATE * OPUS_MAX_FRAME_MS / 1000 * count];
    let mut decoded = Vec::new();
    let mut seen_tags = false;
    while let Some(packet) = packets.read_packet()? {
        if !seen_tags {
            seen_tags = true;
            continue;
        }
        let per_channel = decoder.decode(&packet.data, &mut frame, false)?;
        decoded.extend_from_slice(&mono(&frame[..per_channel * count], count));
        if decoded.len() > MAX_CLIP_SECONDS * SAMPLE_RATE + pre_skip {
            bail!("the clip is longer than {MAX_CLIP_SECONDS} seconds");
        }
    }
    decoded.drain(..pre_skip.min(decoded.len()));
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    const OGG: &[u8] = include_bytes!("../tests/fixtures/tone.ogg");
    const WAV: &[u8] = include_bytes!("../tests/fixtures/tone-8k-stereo.wav");

    fn near(samples: &[i16], seconds: f64) {
        let want = (seconds * SAMPLE_RATE as f64) as i64;
        assert!(
            (samples.len() as i64 - want).abs() < 960,
            "{} samples, wanted about {want}",
            samples.len()
        );
    }

    fn loud(samples: &[i16]) -> bool {
        samples.iter().any(|s| s.unsigned_abs() > 1000)
    }

    #[test]
    fn an_ogg_opus_clip_decodes_to_16k_mono() {
        let samples = decode(OGG).unwrap();
        near(&samples, 0.5);
        assert!(loud(&samples), "the tone survives the codec");
    }

    #[test]
    fn a_stereo_8k_wav_is_mixed_down_and_resampled() {
        let samples = decode(WAV).unwrap();
        near(&samples, 0.25);
        assert!(loud(&samples));
    }

    #[test]
    fn anything_else_is_refused() {
        assert!(decode(b"ID3....").is_err());
        assert!(decode(&OGG[..40]).is_err(), "a truncated header");
        let mut float_wav = WAV.to_vec();
        float_wav[20] = 3;
        assert!(decode(&float_wav).is_err(), "only PCM16");
    }
}
