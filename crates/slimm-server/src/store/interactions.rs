// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A button click awaiting the bot's answer. See
//! `docs/decisions/0039-bot-message-buttons.md`.

use sqlx::Row;

use crate::components::INTERACTION_WINDOW_MS;
use crate::ids::{ChannelId, InteractionId, MessageId, UserId};

use super::{Store, now_ms};

/// What was used: a button on a message, a bot's entry in a message's menu,
/// or a bot's control in a call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InteractionKind {
    Button,
    MessageMenu,
    CallControl,
}

impl InteractionKind {
    pub fn as_str(self) -> &'static str {
        match self {
            InteractionKind::Button => "button",
            InteractionKind::MessageMenu => "message_menu",
            InteractionKind::CallControl => "call_control",
        }
    }

    fn parse(text: &str) -> Self {
        match text {
            "message_menu" => InteractionKind::MessageMenu,
            "call_control" => InteractionKind::CallControl,
            _ => InteractionKind::Button,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Interaction {
    pub id: InteractionId,
    pub bot_id: UserId,
    pub clicker_id: UserId,
    pub channel_id: ChannelId,
    /// Absent for a call control, which is used on a call and not a message.
    pub message_id: Option<MessageId>,
    /// The button's `custom_id`, or the id of the menu entry or call control.
    pub custom_id: String,
    pub kind: InteractionKind,
    /// The option a member chose on a call control that offers a choice.
    pub option_id: Option<String>,
    pub created_at: i64,
    pub answered: bool,
}

impl Store {
    /// Records a click, idempotent by its client-chosen id. `Ok(None)` means
    /// the id already belongs to a different click.
    pub async fn record_interaction(
        &self,
        new: &Interaction,
    ) -> anyhow::Result<Option<(Interaction, bool)>> {
        let inserted = sqlx::query(
            "INSERT OR IGNORE INTO interactions
                (id, bot_id, clicker_id, channel_id, message_id, custom_id, created_at, kind,
                 option_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(new.id)
        .bind(new.bot_id)
        .bind(new.clicker_id)
        .bind(new.channel_id)
        .bind(new.message_id)
        .bind(&new.custom_id)
        .bind(new.created_at)
        .bind(new.kind.as_str())
        .bind(&new.option_id)
        .execute(&self.pool)
        .await?
        .rows_affected()
            == 1;
        let stored = self.interaction(new.id).await?;
        Ok(stored
            .filter(|s| {
                s.clicker_id == new.clicker_id
                    && s.bot_id == new.bot_id
                    && s.kind == new.kind
                    && s.custom_id == new.custom_id
                    && s.channel_id == new.channel_id
                    && s.message_id == new.message_id
                    && s.option_id == new.option_id
            })
            .map(|s| (s, inserted)))
    }

    /// A click still inside its answer window.
    pub async fn interaction(&self, id: InteractionId) -> anyhow::Result<Option<Interaction>> {
        let row = sqlx::query(
            "SELECT id, bot_id, clicker_id, channel_id, message_id, custom_id,
                    created_at, answered_at, kind, option_id
             FROM interactions WHERE id = ? AND created_at > ?",
        )
        .bind(id)
        .bind(now_ms() - INTERACTION_WINDOW_MS)
        .fetch_optional(&self.pool)
        .await?;
        row.map(|r| {
            let answered_at: Option<i64> = r.try_get("answered_at")?;
            let kind: String = r.try_get("kind")?;
            Ok(Interaction {
                id: r.try_get("id")?,
                bot_id: r.try_get("bot_id")?,
                clicker_id: r.try_get("clicker_id")?,
                channel_id: r.try_get("channel_id")?,
                message_id: r.try_get("message_id")?,
                custom_id: r.try_get("custom_id")?,
                created_at: r.try_get("created_at")?,
                kind: InteractionKind::parse(&kind),
                option_id: r.try_get("option_id")?,
                answered: answered_at.is_some(),
            })
        })
        .transpose()
    }

    /// Marks the click answered. True only the first time, so the clicker is
    /// told once.
    pub async fn mark_interaction_answered(&self, id: InteractionId) -> anyhow::Result<bool> {
        Ok(sqlx::query(
            "UPDATE interactions SET answered_at = ? WHERE id = ? AND answered_at IS NULL",
        )
        .bind(now_ms())
        .bind(id)
        .execute(&self.pool)
        .await?
        .rows_affected()
            == 1)
    }

    /// Deletes clicks past their window; returns how many.
    pub async fn sweep_interactions(&self) -> anyhow::Result<u64> {
        Ok(
            sqlx::query("DELETE FROM interactions WHERE created_at <= ?")
                .bind(now_ms() - INTERACTION_WINDOW_MS)
                .execute(&self.pool)
                .await?
                .rows_affected(),
        )
    }
}
