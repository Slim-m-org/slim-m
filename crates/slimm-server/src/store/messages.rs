// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message write paths: send, edit and delete, over embedded SQLite. The
//! read paths (list, fetch by id) are [`super::message_reads`], split out to
//! stay under the file budget. Full-text search is [`super::message_search`].
//!
//! Two invariants live here and are covered by tests:
//!
//! - Ordering. Every message takes the next value from a per-(channel, stream)
//!   counter, allocated inside the same transaction as the insert, so a
//!   channel's messages get a gap-free monotonic `seq` that is independent of
//!   any other channel or of the canvas stream.
//! - Idempotent send. A send is keyed by a client-generated [`MessageId`]; a
//!   retry with the same id returns the stored message and consumes no new
//!   sequence, so an at-least-once client never duplicates or reorders.
//!
//! Delete is soft: `deleted_at` is set, and every read filters on it except
//! [`Store::message_including_deleted`], which a delete handler needs so it
//! can authorize against an already-gone row and stay idempotent.

use anyhow::Context;

pub(in crate::store) mod row;
mod send;

use super::attachments::{LinkError, release_message_attachments};
use super::message_forwards::ForwardOrigin;
use super::message_ops::insert_message_op;
use super::message_reads::fetch_message;
use super::moderation_audit::{ModerationAudit, record_moderation_audit};
use super::{Message, Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

/// The outcome of a send, which is idempotent and so may be a retry.
#[derive(Debug, Clone)]
pub struct Sent {
    pub message: Message,
    /// False when this id was already stored, so the call was a retry of a send
    /// that already succeeded. Everything that must happen exactly once per
    /// message keys off this: fanning the message out again would duplicate it
    /// for every connected client, and pushing again would wake every idle
    /// recipient a second time for a message they were already told about.
    pub fresh: bool,
}

/// Why a message send failed.
#[derive(Debug)]
pub enum SendError {
    /// A message with this id already exists for a different channel or author.
    /// Idempotency is scoped so a colliding id never returns a foreign message.
    IdConflict,
    /// One of the referenced attachment ids was never uploaded, or was
    /// already swept as an orphan before this send reached it.
    AttachmentNotFound,
    /// `reply_to_id` named a message that does not exist, or that exists in a
    /// different channel from this send. A parent that exists in this
    /// channel but is already soft-deleted is still a valid target.
    InvalidReplyTarget,
    /// The author's last send in this channel is still inside the slow-mode window.
    SlowMode {
        retry_after_seconds: i64,
    },
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SendError {
    fn from(err: sqlx::Error) -> Self {
        SendError::Internal(err.into())
    }
}

impl From<anyhow::Error> for SendError {
    fn from(err: anyhow::Error) -> Self {
        SendError::Internal(err)
    }
}

impl From<LinkError> for SendError {
    fn from(err: LinkError) -> Self {
        match err {
            LinkError::NotFound => SendError::AttachmentNotFound,
            LinkError::Internal(e) => SendError::Internal(e),
        }
    }
}

/// What one message delete actually did, so the HTTP handler can tell a
/// caller and the fan-out hub apart from the filesystem cleanup that follows.
#[derive(Debug, Default, Clone)]
pub struct MessageDeletion {
    /// `false` means the message was already gone (a retry after a dropped
    /// response), the same idempotency contract the old boolean return had.
    pub deleted: bool,
    /// Whether the message was pinned at the moment this call deleted it,
    /// read before the soft-delete `UPDATE` fires `pinned_messages_on_delete`.
    /// A retry of an already-gone message is `false`, exactly like `deleted`.
    pub was_pinned: bool,
    /// Hex ids of attachments this delete left with no message referencing
    /// them. Their database rows are already gone; the caller still needs to
    /// delete the backing files, which is filesystem I/O kept outside the
    /// transaction that removed the rows.
    pub freed_attachments: Vec<String>,
    /// The op stream seq this delete allocated, absent when it deleted
    /// nothing. A 200 does not imply the cursor advanced.
    pub op_seq: Option<i64>,
    /// What happened to the forwarded copies of this message.
    pub cascade: super::ForwardCascade,
}

/// What one edit actually did.
///
/// Three ways rather than two, because "no such message" and "the content was
/// already exactly this" need different answers from the caller: only a real
/// change publishes an event, and only a real change allocates an op seq. An
/// edit that changes nothing writing no op row is what keeps the op stream
/// dense, which is what makes a client's `n + 1` a fact rather than a guess.
#[derive(Debug, Clone)]
pub enum Edited {
    /// No live message with that id.
    Gone,
    /// The stored content was already byte-identical, so nothing was written:
    /// no op row, no seq, and `edited_at` is left where it was. The caller
    /// asked for a state and got it, so this is a 200 rather than an error.
    Unchanged(Message),
    Edited {
        message: Message,
        op_seq: i64,
        /// Whether this edit dropped shared `code_runs` rows for the message.
        /// A block's content just changed underneath its stored output, so
        /// every run for the message is cleared rather than trying to track
        /// which block index still matches - see `store::messages::edit_message`.
        code_runs_cleared: bool,
    },
}

/// Everything one send carries.
///
/// A parameter object rather than a positional list: with provenance for
/// both replies and forwards on it, the positional form had reached the
/// point where an ordinary call ended in an empty slice and two bare
/// `None`s, and adding to it meant counting commas.
pub struct NewMessage<'a> {
    pub channel_id: ChannelId,
    pub author_id: UserId,
    pub id: MessageId,
    pub content: &'a str,
    /// sha256 hashes of already-uploaded attachments, in display order.
    pub attachment_ids: &'a [Vec<u8>],
    pub reply_to_id: Option<MessageId>,
    /// What this message forwards, already resolved by the caller with
    /// [`Store::forward_source`] and only after checking the sender can see
    /// the origin's channel. The store writes what it is handed here, so
    /// authorizing the origin is the caller's job and cannot be skipped.
    pub forward: Option<ForwardOrigin>,
}

impl<'a> NewMessage<'a> {
    /// An ordinary message: no attachments, not a reply, not a forward.
    pub fn plain(
        channel_id: ChannelId,
        author_id: UserId,
        id: MessageId,
        content: &'a str,
    ) -> Self {
        Self {
            channel_id,
            author_id,
            id,
            content,
            attachment_ids: &[],
            reply_to_id: None,
            forward: None,
        }
    }
}

impl Store {
    /// Edits a message's content. Returns `None` if it does not exist or is
    /// deleted. The FTS index is kept current by a database trigger.
    pub async fn edit_message(
        &self,
        id: MessageId,
        content: &str,
        actor_id: UserId,
    ) -> anyhow::Result<Edited> {
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query!(
            r#"SELECT content AS "content!: String", channel_id AS "channel_id!: ChannelId"
               FROM messages WHERE id = ? AND deleted_at IS NULL"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(existing) = existing else {
            tx.commit().await?;
            return Ok(Edited::Gone);
        };
        if existing.content == content {
            tx.commit().await?;
            let message = fetch_message(&self.pool, id)
                .await?
                .context("a message read inside the transaction vanished after it")?;
            return Ok(Edited::Unchanged(message));
        }

        let now = now_ms();
        // Capture the version being replaced before the row is overwritten; see migration 0050.
        sqlx::query!(
            "INSERT INTO message_edits (message_id, content, replaced_at) VALUES (?, ?, ?)",
            id,
            existing.content,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "UPDATE messages SET content = ?, edited_at = ? WHERE id = ?",
            content,
            now,
            id
        )
        .execute(&mut *tx)
        .await?;
        // See Edited::Edited::code_runs_cleared for why this is unconditional and whole-message.
        let code_runs_cleared = sqlx::query!("DELETE FROM code_runs WHERE message_id = ?", id)
            .execute(&mut *tx)
            .await?
            .rows_affected()
            > 0;
        let op_seq = insert_message_op(
            &mut tx,
            existing.channel_id,
            id,
            "edit",
            Some(actor_id),
            now,
        )
        .await?;
        tx.commit().await?;

        let message = fetch_message(&self.pool, id)
            .await?
            .context("a message this transaction just edited vanished after it")?;
        Ok(Edited::Edited {
            message,
            op_seq,
            code_runs_cleared,
        })
    }

    /// Soft-deletes a message and releases its attachments. Returns whether
    /// this call performed the delete (`false` means it was already gone),
    /// so a retry after a dropped response stays idempotent and the caller
    /// can skip a redundant fan-out.
    ///
    /// The `UPDATE` is the transaction's first statement, and its `WHERE`
    /// clause is both the claim and the idempotency check, so two racing
    /// deletes of the same message cannot both believe they were the one
    /// that deleted it. Releasing the attachment links happens in the same
    /// transaction, so a message can never end up soft-deleted while still
    /// holding live attachment references.
    ///
    /// When `actor_id` differs from the message's author, this is a
    /// moderator reaching for someone else's message rather than an author
    /// deleting their own, so it is recorded under the same `messages_deleted`
    /// action [`Self::bulk_delete_messages`] writes - the single-message and
    /// bulk paths must not diverge on what an act of the same shape produces.
    /// A self-delete, and a message whose author no longer resolves (mirroring
    /// how the bulk path skips a `None` author), write no row.
    pub async fn delete_message(
        &self,
        id: MessageId,
        actor_id: UserId,
    ) -> anyhow::Result<MessageDeletion> {
        let mut tx = self.begin_write().await?;
        let now = now_ms();
        // Read before the trigger below removes it; see `MessageDeletion::was_pinned`.
        let was_pinned = sqlx::query_scalar!(
            r#"SELECT EXISTS(SELECT 1 FROM pinned_messages WHERE message_id = ?) AS "was_pinned!: bool""#,
            id
        )
        .fetch_one(&mut *tx)
        .await?;
        let claimed = sqlx::query!(
            r#"UPDATE messages SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL
               RETURNING channel_id AS "channel_id!: ChannelId", author_id AS "author_id: UserId""#,
            now,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(claimed) = claimed else {
            tx.commit().await?;
            return Ok(MessageDeletion::default());
        };
        let channel_id = claimed.channel_id;

        let op_seq =
            insert_message_op(&mut tx, channel_id, id, "delete", Some(actor_id), now).await?;
        let freed_attachments = release_message_attachments(&mut tx, id).await?;
        let cascade =
            super::forward_cascade::cascade_to_copies(&mut tx, &[id], Some(actor_id), now).await?;
        if let Some(author_id) = claimed.author_id
            && author_id != actor_id
        {
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id,
                    subject_id: author_id,
                    action: "messages_deleted",
                    reason: None,
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }
        tx.commit().await?;
        Ok(MessageDeletion {
            deleted: true,
            was_pinned,
            freed_attachments,
            op_seq: Some(op_seq),
            cascade,
        })
    }
}
