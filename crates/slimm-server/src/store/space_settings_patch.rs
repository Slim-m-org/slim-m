// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One PATCH of the Space settings, written in a single transaction.

use anyhow::Context;

use super::{Store, now_ms};
use crate::ids::ChannelId;

/// Every field is `None` when the PATCH did not name it.
#[derive(Debug, Default)]
pub struct SpaceSettingsPatch<'a> {
    pub name: Option<&'a str>,
    pub join_policy: Option<&'a str>,
    pub totp_policy: Option<&'a str>,
    pub description: Option<&'a str>,
    pub strong_noise_suppression: Option<bool>,
    pub members_can_invite: Option<bool>,
    pub hide_bots_in_member_list: Option<bool>,
    pub module_member_badges: Option<bool>,
    pub module_profile_sections: Option<bool>,
    pub call_transcription: Option<&'a str>,
    /// Outer `None` leaves the setting alone; inner `None` keeps transcripts forever.
    pub call_transcript_retention_days: Option<Option<i64>>,
    pub transcribe_voice_messages: Option<bool>,
    pub voice_commands: Option<bool>,
    pub voice_command_phrase: Option<&'a str>,
    pub log_mode: Option<&'a str>,
    pub welcome: Option<&'a super::SpaceWelcome>,
}

impl Store {
    /// Writes every named setting or none of them.
    pub async fn apply_space_settings(&self, patch: &SpaceSettingsPatch<'_>) -> anyhow::Result<()> {
        let now = now_ms();
        let (retention_set, retention) = match patch.call_transcript_retention_days {
            Some(days) => (true, days),
            None => (false, None),
        };
        let welcome = patch.welcome;
        let welcome_channel: Option<ChannelId> = welcome.and_then(|w| w.channel_id);
        let mut tx = self.begin_write().await?;
        sqlx::query(
            "UPDATE space_settings SET
                 join_policy = COALESCE(?1, join_policy),
                 totp_policy = COALESCE(?2, totp_policy),
                 description = COALESCE(?3, description),
                 strong_noise_suppression = COALESCE(?4, strong_noise_suppression),
                 members_can_invite = COALESCE(?5, members_can_invite),
                 hide_bots_in_member_list = COALESCE(?6, hide_bots_in_member_list),
                 module_member_badges = COALESCE(?7, module_member_badges),
                 module_profile_sections = COALESCE(?8, module_profile_sections),
                 call_transcription = COALESCE(?9, call_transcription),
                 call_transcript_retention_days =
                     CASE WHEN ?10 = 1 THEN ?11 ELSE call_transcript_retention_days END,
                 transcribe_voice_messages = COALESCE(?12, transcribe_voice_messages),
                 transcription_notice_revised_at = CASE WHEN ?13 = 1 AND voice_commands = 0
                     THEN ?19 ELSE transcription_notice_revised_at END,
                 voice_commands = COALESCE(?13, voice_commands),
                 voice_command_phrase = COALESCE(?14, voice_command_phrase),
                 log_mode = COALESCE(?15, log_mode),
                 welcome_enabled = COALESCE(?16, welcome_enabled),
                 welcome_channel_id = CASE WHEN ?16 IS NULL THEN welcome_channel_id ELSE ?17 END,
                 welcome_message = COALESCE(?18, welcome_message),
                 updated_at = ?19
             WHERE id = 1",
        )
        .bind(patch.join_policy)
        .bind(patch.totp_policy)
        .bind(patch.description)
        .bind(patch.strong_noise_suppression)
        .bind(patch.members_can_invite)
        .bind(patch.hide_bots_in_member_list)
        .bind(patch.module_member_badges)
        .bind(patch.module_profile_sections)
        .bind(patch.call_transcription)
        .bind(retention_set)
        .bind(retention)
        .bind(patch.transcribe_voice_messages)
        .bind(patch.voice_commands)
        .bind(patch.voice_command_phrase)
        .bind(patch.log_mode)
        .bind(welcome.map(|w| w.enabled))
        .bind(welcome_channel)
        .bind(welcome.map(|w| w.message.as_str()))
        .bind(now)
        .execute(&mut *tx)
        .await
        .context("apply space settings")?;
        if let Some(name) = patch.name {
            sqlx::query(
                "INSERT INTO server_meta (key, value) VALUES ('deployment_name', ?)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .bind(name)
            .execute(&mut *tx)
            .await
            .context("apply space name")?;
        }
        tx.commit().await?;
        Ok(())
    }
}
