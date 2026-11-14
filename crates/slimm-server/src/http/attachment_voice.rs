// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The query a client adds to an upload to mark it as a voice message: the
//! length and the loudness buckets its player draws. Audio only, so the flag
//! cannot dress a file up as something the player would then try to play.

use serde::Deserialize;

use super::AppState;
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

/// Stores the voice data once the bytes are placed, returning what the response carries.
///
/// A voice upload that is not audio is refused here, after the bytes are stored: they are an
/// ordinary orphan the sweep reclaims, the same as any upload never attached.
pub(super) async fn record(
    state: &AppState,
    sha256: &[u8],
    content_type: &str,
    request: Option<VoiceInfo>,
) -> Result<Option<VoiceInfo>, ApiError> {
    let Some(voice) = request else {
        return Ok(None);
    };
    if !content_type.starts_with("audio/") {
        return Err(ApiError::BadRequest("a voice message must be audio"));
    }
    state.store.set_attachment_voice(sha256, &voice).await?;
    Ok(Some(voice))
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
