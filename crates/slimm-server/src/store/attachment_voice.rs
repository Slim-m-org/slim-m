// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What marks an audio attachment as a voice message: its length and the
//! loudness buckets the player draws. See migration 0187.

use super::Store;

/// Loudness buckets in a waveform; the client draws exactly this many bars.
pub const WAVEFORM_BUCKETS: usize = 64;

/// The longest voice message the client records, plus slack for the encoder's tail.
pub const MAX_VOICE_MS: i64 = 5 * 60 * 1000 + 10_000;

/// A voice message's player data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceInfo {
    pub duration_ms: i64,
    pub waveform: Vec<u8>,
}

impl VoiceInfo {
    /// `None` for a row that is not a voice message (both columns null).
    pub(super) fn from_columns(
        duration_ms: Option<i64>,
        waveform: Option<Vec<u8>>,
    ) -> Option<Self> {
        Some(Self {
            duration_ms: duration_ms?,
            waveform: waveform?,
        })
    }
}

impl Store {
    /// Marks `sha256` as a voice message. The first upload of a blob decides; a repeat is ignored.
    pub async fn set_attachment_voice(
        &self,
        sha256: &[u8],
        voice: &VoiceInfo,
    ) -> anyhow::Result<()> {
        sqlx::query!(
            "INSERT INTO attachment_voice (sha256, duration_ms, waveform)
             SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)
             ON CONFLICT (sha256) DO NOTHING",
            sha256,
            voice.duration_ms,
            voice.waveform,
            sha256,
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
