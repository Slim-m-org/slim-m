// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message's edit history: the versions it has held, reconstructed from the
//! `message_edits` rows [`Store::edit_message`] writes. Split out of
//! `messages.rs` to keep that file under the line ceiling.

use super::super::Store;
use super::message_reads::fetch_message;
use crate::ids::MessageId;

/// One version a message has held, oldest first in a
/// [`Store::message_edit_history`] list. `at` is when this version became the
/// message's content: the message's own `created_at` for the original, and
/// the moment of the edit that produced each later one. The last element is
/// always the current content.
#[derive(Debug, Clone)]
pub struct MessageRevision {
    pub content: String,
    pub at: i64,
}

impl Store {
    /// Every version a live message has held, oldest first, ending with its
    /// current content. `None` for a message that does not exist or is
    /// deleted, the same gate [`Store::message`] and [`Store::edit_message`]
    /// use, so a deleted message exposes no history.
    ///
    /// A never-edited message returns a single element - its original content
    /// at its `created_at`. `message_edits` holds each version this message
    /// replaced, in insertion order; the version live before edit `k` sits in
    /// row `k`, so its "became live at" is the previous row's `replaced_at`,
    /// and the original's is the message's own `created_at`.
    pub async fn message_edit_history(
        &self,
        id: MessageId,
    ) -> anyhow::Result<Option<Vec<MessageRevision>>> {
        // One read snapshot for both, so a concurrent edit cannot leave the current content and the captured versions disagreeing.
        let mut tx = self.begin_read().await?;
        let Some(message) = fetch_message(&mut *tx, id).await? else {
            return Ok(None);
        };
        let replaced = sqlx::query!(
            r#"SELECT content AS "content!: String", replaced_at AS "replaced_at!: i64"
               FROM message_edits WHERE message_id = ? ORDER BY id ASC"#,
            id
        )
        .fetch_all(&mut *tx)
        .await?;

        let mut history = Vec::with_capacity(replaced.len() + 1);
        let mut became_live = message.created_at;
        for row in &replaced {
            history.push(MessageRevision {
                content: row.content.clone(),
                at: became_live,
            });
            became_live = row.replaced_at;
        }
        history.push(MessageRevision {
            content: message.content.clone(),
            at: became_live,
        });
        Ok(Some(history))
    }
}
