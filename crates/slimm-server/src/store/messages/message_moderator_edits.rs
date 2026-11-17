// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whether a message's current text was written by someone other than its
//! author. Read from the `edit` op whose time is the message's `edited_at`,
//! so a moderator removing link previews (also an `edit` op) never counts.

use std::collections::HashSet;

use super::super::Store;
use crate::ids::MessageId;

/// True for a message `m` whose latest text edit was by someone other than its
/// author. `message_ops.rs`'s sync query repeats it, since `query!` needs a literal.
pub(crate) const MODERATOR_EDITED_SQL: &str = "EXISTS (SELECT 1 FROM message_ops o \
     WHERE o.channel_id = m.channel_id AND o.message_id = m.id AND o.kind = 'edit' \
       AND o.created_at = m.edited_at AND o.actor_id IS NOT NULL \
       AND o.actor_id != m.author_id)";

impl Store {
    /// Whether `message_id`'s current text was a moderator's edit.
    pub async fn moderator_edited(&self, message_id: MessageId) -> anyhow::Result<bool> {
        Ok(self
            .moderator_edited_among(&[message_id])
            .await?
            .contains(&message_id))
    }

    /// The subset of `message_ids` whose current text was a moderator's edit.
    pub async fn moderator_edited_among(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<HashSet<MessageId>> {
        use sqlx::Row;
        let mut edited = HashSet::new();
        for chunk in message_ids.chunks(super::super::MAX_IDS_PER_QUERY) {
            let mut builder = sqlx::QueryBuilder::new(
                "SELECT m.id AS id FROM messages m WHERE m.edited_at IS NOT NULL AND m.id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(") AND ");
            builder.push(MODERATOR_EDITED_SQL);
            for row in builder.build().fetch_all(&self.pool).await? {
                edited.insert(row.try_get("id")?);
            }
        }
        Ok(edited)
    }
}
