// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The spoken-mark settings in `PATCH /space/settings`: checked before anything
//! is written, and refused while the Space does not transcribe calls.

use super::AppState;
use super::error::ApiError;
use crate::call_audio::commands::WakePhrase;
use crate::store::TranscriptionMode;

/// What a PATCH asks of the switch and the phrase, after checking.
pub(super) struct VoiceCommandsChange {
    pub(super) on: Option<bool>,
    pub(super) phrase: Option<String>,
}

/// `None` when the body names neither. `transcription` is the mode this same PATCH sets, if any.
pub(super) async fn check(
    state: &AppState,
    on: Option<bool>,
    phrase: Option<&str>,
    transcription: Option<TranscriptionMode>,
) -> Result<Option<VoiceCommandsChange>, ApiError> {
    if on.is_none() && phrase.is_none() {
        return Ok(None);
    }
    let phrase = phrase
        .map(|raw| WakePhrase::parse(raw).map(|p| p.text()))
        .transpose()
        .map_err(ApiError::BadRequest)?;
    if on == Some(true) {
        let mode = match transcription {
            Some(mode) => mode,
            None => state.store.call_transcription().await?,
        };
        if mode == TranscriptionMode::Off || !state.call_audio.is_enabled() {
            return Err(ApiError::Conflict(
                "voice commands need call transcription, which is off",
            ));
        }
    }
    Ok(Some(VoiceCommandsChange { on, phrase }))
}
