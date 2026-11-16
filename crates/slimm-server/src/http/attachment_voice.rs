// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The query a client adds to an upload to mark it as a voice message: the
//! length and the loudness buckets its player draws. Audio only.

use serde::Deserialize;

use super::error::ApiError;
use crate::store::{MAX_VOICE_MS, VoiceInfo, WAVEFORM_BUCKETS};

/// Strings on the wire: a flattened query cannot carry typed numbers.
#[derive(Deserialize, Default)]
pub(super) struct VoiceParams {
    voice: Option<String>,
    duration_ms: Option<String>,
    /// One hex byte per bucket.
    waveform: Option<String>,
}

impl VoiceParams {
    /// `None` when the upload is not a voice message; a malformed request is a 400.
    pub(super) fn parse(&self) -> Result<Option<VoiceInfo>, ApiError> {
        if self.voice.as_deref() != Some("true") {
            return Ok(None);
        }
        let duration_ms: i64 = self
            .duration_ms
            .as_deref()
            .and_then(|raw| raw.parse().ok())
            .filter(|ms| (1..=MAX_VOICE_MS).contains(ms))
            .ok_or(ApiError::BadRequest("a voice message needs a duration_ms"))?;
        let waveform = self
            .waveform
            .as_deref()
            .and_then(decode_hex)
            .filter(|bytes| bytes.len() == WAVEFORM_BUCKETS)
            .ok_or(ApiError::BadRequest(
                "a voice message needs a 64 byte waveform",
            ))?;
        Ok(Some(VoiceInfo {
            duration_ms,
            waveform,
        }))
    }
}

fn decode_hex(raw: &str) -> Option<Vec<u8>> {
    if !raw.len().is_multiple_of(2) || !raw.is_ascii() {
        return None;
    }
    (0..raw.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&raw[at..at + 2], 16).ok())
        .collect()
}

/// Refuses a voice mark on anything that is not audio, before the bytes are kept, so the flag
/// cannot dress a file up as something the player would then try to play.
pub(super) fn must_be_audio(voice: Option<&VoiceInfo>, content_type: &str) -> Result<(), ApiError> {
    match voice {
        Some(_) if !content_type.starts_with("audio/") => {
            Err(ApiError::BadRequest("a voice message must be audio"))
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(voice: &str, ms: &str, waveform: &str) -> VoiceParams {
        VoiceParams {
            voice: Some(voice.into()),
            duration_ms: Some(ms.into()),
            waveform: Some(waveform.into()),
        }
    }

    #[test]
    fn a_plain_upload_is_not_a_voice_message() {
        assert!(matches!(VoiceParams::default().parse(), Ok(None)));
    }

    #[test]
    fn a_well_formed_request_parses() {
        let hex = "0a".repeat(WAVEFORM_BUCKETS);
        let Ok(Some(voice)) = params("true", "1500", &hex).parse() else {
            panic!("a well-formed request parses");
        };
        assert_eq!(voice.duration_ms, 1500);
        assert_eq!(voice.waveform, vec![10; WAVEFORM_BUCKETS]);
    }

    #[test]
    fn only_audio_can_be_a_voice_message() {
        let voice = VoiceInfo {
            duration_ms: 1,
            waveform: vec![0; WAVEFORM_BUCKETS],
        };
        assert!(must_be_audio(Some(&voice), "audio/ogg").is_ok());
        assert!(must_be_audio(Some(&voice), "image/png").is_err());
        assert!(must_be_audio(None, "image/png").is_ok());
    }

    #[test]
    fn a_bad_duration_or_waveform_is_refused() {
        let hex = "0a".repeat(WAVEFORM_BUCKETS);
        assert!(params("true", "0", &hex).parse().is_err());
        assert!(params("true", "9999999", &hex).parse().is_err());
        assert!(params("true", "abc", &hex).parse().is_err());
        assert!(params("true", "1500", "0a0a").parse().is_err());
        assert!(
            params("true", "1500", &"zz".repeat(WAVEFORM_BUCKETS))
                .parse()
                .is_err()
        );
    }
}
