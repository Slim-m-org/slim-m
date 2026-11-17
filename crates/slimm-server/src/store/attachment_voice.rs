// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What marks an audio attachment as a voice message: its length and the
//! loudness buckets the player draws. Kept per uploader and per message link,
//! never per blob, since the same bytes can be one member's voice message and
//! another's plain file. See migration 0194.

use super::Store;
use super::attachment_originals::insert_attachment;
use crate::ids::UserId;

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
    /// [`Store::store_attachment`] for an upload the client marked as a voice message. The mark
    /// is this uploader's alone: their next send of these bytes carries it, nobody else's does.
    pub async fn store_voice_attachment(
        &self,
        sha256: &[u8],
        size: i64,
        content_type: &str,
        filename: &str,
        uploader: UserId,
        voice: &VoiceInfo,
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        insert_attachment(
            &mut tx,
            sha256,
            size,
            content_type,
            filename,
            Some(uploader),
        )
        .await?;
        sqlx::query!(
            "UPDATE attachment_uploaders SET voice_duration_ms = ?, voice_waveform = ?
             WHERE sha256 = ? AND uploaded_by = ?",
            voice.duration_ms,
            voice.waveform,
            sha256,
            uploader,
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    /// The voice data `uploader`'s own upload of `sha256` carries, which a send of theirs would.
    pub async fn uploaded_voice(
        &self,
        sha256: &[u8],
        uploader: UserId,
    ) -> anyhow::Result<Option<VoiceInfo>> {
        let row = sqlx::query!(
            r#"SELECT voice_duration_ms AS "duration_ms?: i64",
                      voice_waveform AS "waveform?: Vec<u8>"
               FROM attachment_uploaders WHERE sha256 = ? AND uploaded_by = ?"#,
            sha256,
            uploader
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.and_then(|r| VoiceInfo::from_columns(r.duration_ms, r.waveform)))
    }
}
