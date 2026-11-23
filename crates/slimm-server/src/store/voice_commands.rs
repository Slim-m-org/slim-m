// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space's spoken-mark switch and wake phrase (decision 0113, amended
//! 2026-11-22), and when the transcription notice last changed because of them.

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::UserId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceCommands {
    pub on: bool,
    pub phrase: String,
}

impl Store {
    /// Off with the default phrase when the row is missing.
    pub async fn voice_commands(&self) -> anyhow::Result<VoiceCommands> {
        let row = sqlx::query!(
            r#"SELECT voice_commands AS "on!: bool", voice_command_phrase AS "phrase!: String"
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read voice commands")?;
        Ok(row.map_or_else(
            || VoiceCommands {
                on: false,
                phrase: crate::call_audio::commands::DEFAULT_PHRASE.to_owned(),
            },
            |r| VoiceCommands {
                on: r.on,
                phrase: r.phrase,
            },
        ))
    }

    /// Writes what is given. Turning the switch from off to on makes the notice due again.
    pub async fn set_voice_commands(
        &self,
        on: Option<bool>,
        phrase: Option<&str>,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET
                 transcription_notice_revised_at = CASE WHEN ?1 = 1 AND voice_commands = 0
                     THEN ?3 ELSE transcription_notice_revised_at END,
                 voice_commands = COALESCE(?1, voice_commands),
                 voice_command_phrase = COALESCE(?2, voice_command_phrase),
                 updated_at = ?3
             WHERE id = 1",
            on,
            phrase,
            now
        )
        .execute(&self.pool)
        .await
        .context("set voice commands")?;
        Ok(())
    }

    /// Whether the member acknowledged the notice since it last changed.
    pub async fn transcription_notice_acknowledged(&self, user: UserId) -> anyhow::Result<bool> {
        let row = sqlx::query!(
            r#"SELECT u.transcription_notice_ack_at AS "ack: i64",
                      (SELECT transcription_notice_revised_at FROM space_settings WHERE id = 1)
                          AS "revised: i64"
               FROM users u WHERE u.id = ?"#,
            user
        )
        .fetch_optional(&self.pool)
        .await
        .context("read transcription notice acknowledgement")?;
        Ok(row.is_some_and(|r| match (r.ack, r.revised) {
            (Some(ack), Some(revised)) => ack >= revised,
            (ack, None) => ack.is_some(),
            (None, Some(_)) => false,
        }))
    }
}
