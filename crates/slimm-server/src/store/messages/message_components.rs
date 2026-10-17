// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Buttons on a bot's message: a side table, never a column on
//! [`super::super::Message`]. See `docs/decisions/0039-bot-message-buttons.md`.

use sqlx::Row;

use crate::components::ComponentRow;
use crate::ids::MessageId;

use super::super::Store;

impl Store {
    /// Replaces the message's buttons whole; an empty list clears them.
    pub async fn set_message_components(
        &self,
        message_id: MessageId,
        rows: &[ComponentRow],
    ) -> anyhow::Result<()> {
        if rows.is_empty() {
            sqlx::query("DELETE FROM message_components WHERE message_id = ?")
                .bind(message_id)
                .execute(&self.pool)
                .await?;
            return Ok(());
        }
        let json = serde_json::to_string(rows)?;
        sqlx::query(
            "INSERT INTO message_components (message_id, components) VALUES (?, ?)
             ON CONFLICT(message_id) DO UPDATE SET components = excluded.components",
        )
        .bind(message_id)
        .bind(json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// The buttons of each of `message_ids` that carries any, batched like
    /// [`Store::embeds_for_messages`].
    pub async fn components_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, Vec<ComponentRow>)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT message_id, components FROM message_components WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        let rows = builder.build().fetch_all(&self.pool).await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let id: MessageId = row.try_get("message_id")?;
            let json: String = row.try_get("components")?;
            out.push((id, serde_json::from_str(&json)?));
        }
        Ok(out)
    }

    /// One message's buttons, empty when it carries none.
    pub async fn components_for_message(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Vec<ComponentRow>> {
        Ok(self
            .components_for_messages(&[message_id])
            .await?
            .into_iter()
            .next()
            .map(|(_, rows)| rows)
            .unwrap_or_default())
    }
}
