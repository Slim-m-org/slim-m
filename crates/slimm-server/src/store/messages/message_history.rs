// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A message's edit history: the versions it has held, reconstructed from the
//! `message_edits` rows [`Store::edit_message`] writes. Split out of
//! `messages.rs` to keep that file under the line ceiling.

use super::super::Store;
use super::message_reads::fetch_message;
use crate::ids::MessageId;

/// Superseded versions kept per message: the original plus the newest edits.
pub const MAX_EDIT_REVISIONS: i64 = 50;
const KEPT_NEWEST: i64 = MAX_EDIT_REVISIONS - 1;

/// Drops the oldest edits except the original, so a message holds at most [`MAX_EDIT_REVISIONS`].
///
/// A dropped version folds into the next, which then reads as live from the dropped one's start.
pub(in crate::store) async fn trim_edit_history(
    tx: &mut sqlx::SqliteConnection,
    id: MessageId,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "DELETE FROM message_edits WHERE message_id = ?1
           AND id > (SELECT MIN(id) FROM message_edits WHERE message_id = ?1)
           AND id <= (SELECT id FROM message_edits WHERE message_id = ?1
                      ORDER BY id DESC LIMIT 1 OFFSET ?2)",
    )
    .bind(id)
    .bind(KEPT_NEWEST)
    .execute(tx)
    .await?;
    Ok(())
}

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
    /// Past [`MAX_EDIT_REVISIONS`] it returns the original and the newest
    /// edits; versions between them were trimmed by [`trim_edit_history`].
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
        // The same rows the trim keeps, so a message not yet trimmed still answers a bounded page.
        let replaced = sqlx::query_as::<_, (String, i64)>(
            "SELECT content, replaced_at FROM message_edits
             WHERE message_id = ?1
               AND (id = (SELECT MIN(id) FROM message_edits WHERE message_id = ?1)
                    OR id > COALESCE((SELECT id FROM message_edits WHERE message_id = ?1
                                      ORDER BY id DESC LIMIT 1 OFFSET ?2), 0))
             ORDER BY id ASC",
        )
        .bind(id)
        .bind(KEPT_NEWEST)
        .fetch_all(&mut *tx)
        .await?;

        let mut history = Vec::with_capacity(replaced.len() + 1);
        let mut became_live = message.created_at;
        for (content, replaced_at) in replaced {
            history.push(MessageRevision {
                content,
                at: became_live,
            });
            became_live = replaced_at;
        }
        history.push(MessageRevision {
            content: message.content.clone(),
            at: became_live,
        });
        Ok(Some(history))
    }
}
