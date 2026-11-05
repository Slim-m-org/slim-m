// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Persistence for a member's opt-in voice notices (decision 0107). A row exists only while
//! at least one of its choices is on; writing "off, no streams" removes it.

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};
use crate::voice_notify::{JoinMode, VoiceNotifyChoice};

impl Store {
    /// Sets or replaces `user_id`'s choice for `channel_id`; an all-off choice clears it.
    pub async fn set_voice_notify_choice(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        choice: VoiceNotifyChoice,
    ) -> anyhow::Result<()> {
        if choice.is_off() {
            sqlx::query!(
                "DELETE FROM voice_notify_prefs WHERE user_id = ? AND channel_id = ?",
                user_id,
                channel_id
            )
            .execute(&self.pool)
            .await?;
            return Ok(());
        }
        let (joins, streams, now) = (choice.joins.as_str(), choice.streams, now_ms());
        sqlx::query!(
            "INSERT INTO voice_notify_prefs (user_id, channel_id, joins, streams, updated_at)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT (user_id, channel_id)
             DO UPDATE SET joins = excluded.joins, streams = excluded.streams,
                           updated_at = excluded.updated_at",
            user_id,
            channel_id,
            joins,
            streams,
            now
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// `user_id`'s choice for `channel_id`, off when there is none.
    pub async fn voice_notify_choice(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> anyhow::Result<VoiceNotifyChoice> {
        let row = sqlx::query!(
            r#"SELECT joins AS "joins!", streams AS "streams!: bool"
               FROM voice_notify_prefs WHERE user_id = ? AND channel_id = ?"#,
            user_id,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(
            row.map_or_else(VoiceNotifyChoice::default, |r| VoiceNotifyChoice {
                joins: JoinMode::parse(&r.joins).unwrap_or_default(),
                streams: r.streams,
            }),
        )
    }

    /// Every channel `user_id` has switched something on for.
    pub async fn list_voice_notify_choices(
        &self,
        user_id: UserId,
    ) -> anyhow::Result<Vec<(ChannelId, VoiceNotifyChoice)>> {
        let rows = sqlx::query!(
            r#"SELECT channel_id AS "channel_id!: ChannelId", joins AS "joins!",
                      streams AS "streams!: bool"
               FROM voice_notify_prefs WHERE user_id = ? ORDER BY updated_at"#,
            user_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let choice = VoiceNotifyChoice {
                    joins: JoinMode::parse(&r.joins).unwrap_or_default(),
                    streams: r.streams,
                };
                (r.channel_id, choice)
            })
            .collect())
    }

    /// Everyone who switched something on for `channel_id`, for the fan-out.
    pub async fn voice_notify_members(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<(UserId, VoiceNotifyChoice)>> {
        let rows = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId", joins AS "joins!",
                      streams AS "streams!: bool"
               FROM voice_notify_prefs WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let choice = VoiceNotifyChoice {
                    joins: JoinMode::parse(&r.joins).unwrap_or_default(),
                    streams: r.streams,
                };
                (r.user_id, choice)
            })
            .collect())
    }
}
