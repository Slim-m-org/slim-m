// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Embeds: a side table, never a column on [`super::Message`]. See
//! `docs/decisions/0030-incoming-webhooks.md`.

use crate::ids::MessageId;

use super::Store;

/// One field on an embed - Discord's own `name`/`value`/`inline` shape.
#[derive(Debug, Clone)]
pub struct NewEmbedField {
    pub name: String,
    pub value: String,
    pub inline: bool,
}

/// One embed, already validated and capped by `http::embeds`.
#[derive(Debug, Clone, Default)]
pub struct NewEmbed {
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    /// Raw 24-bit RGB; see `http::embeds::accent_for`.
    pub color: Option<i64>,
    pub author_name: Option<String>,
    pub author_url: Option<String>,
    pub footer_text: Option<String>,
    pub timestamp: Option<i64>,
    /// Already passed `http::link_preview::ssrf::validate`.
    pub image_url: Option<String>,
    pub thumbnail_url: Option<String>,
    pub fields: Vec<NewEmbedField>,
}

/// One field as stored, read back for [`Embed::fields`].
#[derive(Debug, Clone)]
pub struct EmbedField {
    pub name: String,
    pub value: String,
    pub inline: bool,
}

/// One embed as read back, in the same shape [`NewEmbed`] was written in.
#[derive(Debug, Clone, Default)]
pub struct Embed {
    pub title: Option<String>,
    pub description: Option<String>,
    pub url: Option<String>,
    pub color: Option<i64>,
    pub author_name: Option<String>,
    pub author_url: Option<String>,
    pub footer_text: Option<String>,
    pub timestamp: Option<i64>,
    pub image_url: Option<String>,
    pub thumbnail_url: Option<String>,
    pub fields: Vec<EmbedField>,
}

impl From<NewEmbed> for Embed {
    fn from(e: NewEmbed) -> Self {
        Self {
            title: e.title,
            description: e.description,
            url: e.url,
            color: e.color,
            author_name: e.author_name,
            author_url: e.author_url,
            footer_text: e.footer_text,
            timestamp: e.timestamp,
            image_url: e.image_url,
            thumbnail_url: e.thumbnail_url,
            fields: e
                .fields
                .into_iter()
                .map(|f| EmbedField {
                    name: f.name,
                    value: f.value,
                    inline: f.inline,
                })
                .collect(),
        }
    }
}

/// Writes `embeds` inside the caller's transaction, so a message and its
/// embeds can commit or roll back together.
pub(super) async fn insert_embeds(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    message_id: MessageId,
    embeds: &[NewEmbed],
) -> anyhow::Result<()> {
    for (position, embed) in embeds.iter().enumerate() {
        let position = position as i64;
        sqlx::query!(
            "INSERT INTO message_embeds
                    (message_id, position, title, description, url, color,
                     author_name, author_url, footer_text, embed_timestamp,
                     image_url, thumbnail_url)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            message_id,
            position,
            embed.title,
            embed.description,
            embed.url,
            embed.color,
            embed.author_name,
            embed.author_url,
            embed.footer_text,
            embed.timestamp,
            embed.image_url,
            embed.thumbnail_url,
        )
        .execute(&mut **tx)
        .await?;
        for (field_index, field) in embed.fields.iter().enumerate() {
            let field_index = field_index as i64;
            let inline = field.inline as i64;
            sqlx::query!(
                "INSERT INTO message_embed_fields
                        (message_id, position, field_index, name, value, inline)
                     VALUES (?, ?, ?, ?, ?, ?)",
                message_id,
                position,
                field_index,
                field.name,
                field.value,
                inline,
            )
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}

impl Store {
    /// Stores `embeds`, in order, against `message_id` - insert only, called
    /// at most once per message; a bot's edit goes through
    /// [`Self::replace_message_embeds`] instead.
    pub async fn set_message_embeds(
        &self,
        message_id: MessageId,
        embeds: &[NewEmbed],
    ) -> anyhow::Result<()> {
        if embeds.is_empty() {
            return Ok(());
        }
        let mut tx = self.begin_write().await?;
        insert_embeds(&mut tx, message_id, embeds).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Replaces every embed on `message_id` with `embeds`, in one
    /// transaction; an empty list clears them.
    pub async fn replace_message_embeds(
        &self,
        message_id: MessageId,
        embeds: &[NewEmbed],
    ) -> anyhow::Result<()> {
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "DELETE FROM message_embed_fields WHERE message_id = ?",
            message_id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM message_embeds WHERE message_id = ?",
            message_id
        )
        .execute(&mut *tx)
        .await?;
        insert_embeds(&mut tx, message_id, embeds).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Every embed for each of `message_ids`, ordered by position, batched
    /// like [`super::attachments_for_messages`].
    pub async fn embeds_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, Vec<Embed>)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut embed_builder = sqlx::QueryBuilder::new(
            "SELECT message_id, position, title, description, url, color, \
             author_name, author_url, footer_text, embed_timestamp, \
             image_url, thumbnail_url \
             FROM message_embeds WHERE message_id IN (",
        );
        let mut separated = embed_builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        embed_builder.push(") ORDER BY message_id, position ASC");

        use sqlx::Row;
        let embed_rows = embed_builder.build().fetch_all(&self.pool).await?;

        let mut fields_builder = sqlx::QueryBuilder::new(
            "SELECT message_id, position, field_index, name, value, inline \
             FROM message_embed_fields WHERE message_id IN (",
        );
        let mut separated = fields_builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        fields_builder.push(") ORDER BY message_id, position, field_index ASC");
        let field_rows = fields_builder.build().fetch_all(&self.pool).await?;

        // Keyed by (message_id, position) so a field lands on the right embed despite two separate queries.
        let mut fields_by_embed: std::collections::HashMap<(MessageId, i64), Vec<EmbedField>> =
            std::collections::HashMap::new();
        for row in field_rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let position: i64 = row.try_get("position")?;
            let inline: i64 = row.try_get("inline")?;
            fields_by_embed
                .entry((message_id, position))
                .or_default()
                .push(EmbedField {
                    name: row.try_get("name")?,
                    value: row.try_get("value")?,
                    inline: inline != 0,
                });
        }

        let mut grouped: Vec<(MessageId, Vec<Embed>)> = Vec::new();
        for row in embed_rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let position: i64 = row.try_get("position")?;
            let embed = Embed {
                title: row.try_get("title")?,
                description: row.try_get("description")?,
                url: row.try_get("url")?,
                color: row.try_get("color")?,
                author_name: row.try_get("author_name")?,
                author_url: row.try_get("author_url")?,
                footer_text: row.try_get("footer_text")?,
                timestamp: row.try_get("embed_timestamp")?,
                image_url: row.try_get("image_url")?,
                thumbnail_url: row.try_get("thumbnail_url")?,
                fields: fields_by_embed
                    .remove(&(message_id, position))
                    .unwrap_or_default(),
            };
            match grouped.iter_mut().find(|(id, _)| *id == message_id) {
                Some((_, list)) => list.push(embed),
                None => grouped.push((message_id, vec![embed])),
            }
        }
        Ok(grouped)
    }
}
