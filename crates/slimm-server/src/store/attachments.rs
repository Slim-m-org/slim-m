// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Attachment metadata persistence: the content-addressed `attachments` rows,
//! the join table linking them to messages, and the sweep that reclaims an
//! upload nobody ever sent a message with.
//!
//! Two-phase by necessity (upload, then reference at send time) rather than
//! one atomic operation: the client uploads bytes before it knows whether the
//! send it is about to make will succeed, so nothing can make "upload" and
//! "attach to a message" one transaction - there is no message row yet. What
//! *is* transactional is the second half: linking an already-uploaded
//! attachment to a message happens inside the same transaction as the
//! message insert ([`link_attachments`], composed into
//! `Store::send_message`), so a message is never visible with only some of
//! its attachments recorded. The gap that leaves open - an upload nobody
//! ever attached to anything - is what
//! [`Store::sweep_orphaned_attachments`] reclaims, on the same periodic-sweep
//! model as `Store::sweep_expired_tokens`.

use sqlx::QueryBuilder;

pub(super) mod refs;

use super::{Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use refs::{held_sql, is_referenced};

/// Most attachments one message may carry. Without a cap the join table (and
/// the per-send linking work, and the permission check on fetch) is an
/// unbounded write target.
pub const MAX_ATTACHMENTS_PER_MESSAGE: usize = 10;

/// How long an uploaded-but-never-attached attachment survives before the
/// sweep reclaims it. Generous: nothing about a normal compose flow (upload,
/// then send the message that references it) should take anywhere near this
/// long.
pub(super) const ORPHAN_GRACE_MS: i64 = 24 * 60 * 60 * 1000;

/// How many orphaned rows one sweep pass deletes, bounding how long it can
/// hold the write lock. Smaller than `Store::sweep_expired_tokens`'s batch:
/// each row here has a file to delete behind it too.
const ORPHAN_SWEEP_BATCH: i64 = 500;

/// One uploaded attachment's metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentSummary {
    /// The sha256 of the stored bytes, hex-encoded: also the id a client
    /// references it by and the path segment it is fetched at.
    pub id: String,
    pub filename: String,
    pub content_type: String,
    pub size: i64,
}

/// Why linking an already-uploaded attachment to a message failed.
#[derive(Debug)]
pub enum LinkError {
    /// This id was never uploaded, or was already swept as an orphan.
    NotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for LinkError {
    fn from(err: sqlx::Error) -> Self {
        LinkError::Internal(err.into())
    }
}

impl From<anyhow::Error> for LinkError {
    fn from(err: anyhow::Error) -> Self {
        LinkError::Internal(err)
    }
}

impl Store {
    /// Records a freshly uploaded attachment's metadata. Idempotent by
    /// content hash: uploading bytes that already exist leaves the original
    /// row (and its filename) in place rather than overwriting it, the same
    /// trade-off content addressing already makes for the storage itself.
    ///
    /// The one field a re-upload does refresh is `created_at`, which the orphan
    /// sweep measures its grace window from. Left stale, re-uploading bytes
    /// that were first uploaded a day ago and never attached let the hourly
    /// sweep delete the just-rewritten file inside the compose window, so the
    /// send then failed. Refreshing it restarts the window on every upload.
    ///
    /// `key_version` and `is_encrypted` are written as 0 explicitly rather
    /// than relying on the column defaults 0002 chose (`is_encrypted DEFAULT
    /// 1`): v1 is transport-only encryption, the same reality
    /// `messages.is_encrypted` already reflects. Changing a STRICT table's
    /// column default in place is not a plain `ALTER TABLE`, so that default
    /// is left as 0002 wrote it rather than migrated away, and simply never
    /// relied upon.
    ///
    /// `uploader` records this caller in `attachment_uploaders`, the table
    /// [`link_attachments`] reads to decide who may reference these bytes in
    /// a message. `None` for the bulk emoji import, which no account
    /// performed. The two inserts share one transaction so a crash between
    /// them can never leave an `attachments` row nobody is recorded as being
    /// able to link.
    pub async fn store_attachment(
        &self,
        sha256: &[u8],
        size: i64,
        content_type: &str,
        filename: &str,
        uploader: Option<UserId>,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "INSERT INTO attachments (sha256, size, content_type, key_version, is_encrypted, filename, created_at)
             VALUES (?, ?, ?, 0, 0, ?, ?)
             ON CONFLICT (sha256) DO UPDATE SET created_at = excluded.created_at",
            sha256,
            size,
            content_type,
            filename,
            now
        )
        .execute(&mut *tx)
        .await?;
        if let Some(uploader) = uploader {
            sqlx::query!(
                "INSERT INTO attachment_uploaders (sha256, uploaded_by, uploaded_at, filename)
                 VALUES (?, ?, ?, ?)
                 ON CONFLICT (sha256, uploaded_by) DO UPDATE SET filename = excluded.filename",
                sha256,
                uploader,
                now,
                filename
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// One attachment's metadata by content hash, regardless of whether it
    /// has been attached to any message yet.
    pub async fn attachment_summary(
        &self,
        sha256: &[u8],
    ) -> anyhow::Result<Option<AttachmentSummary>> {
        let row = sqlx::query!(
            r#"SELECT sha256 AS "sha256!: Vec<u8>", filename AS "filename!",
                      content_type AS "content_type!", size AS "size!"
               FROM attachments WHERE sha256 = ?"#,
            sha256
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| AttachmentSummary {
            id: crate::media::to_hex(&r.sha256),
            filename: r.filename,
            content_type: r.content_type,
            size: r.size,
        }))
    }

    /// Every channel with a live message, or a canvas object, referencing
    /// this attachment. Used only to decide the fetch permission: a caller
    /// may read the bytes if they hold VIEW_CHANNEL in *any* channel that has
    /// attached them, since content already visible to them in one channel
    /// does not become more sensitive for also being attached somewhere else.
    ///
    /// A canvas placement is not filtered on `deleted_at IS NULL` the way a
    /// message is: an erased canvas object can be un-erased by a `restore`
    /// op, so a channel's own VIEW_CHANNEL is still the right question to ask
    /// while it is soft-deleted, not a reason to withdraw fetch access.
    pub async fn channels_referencing_attachment(
        &self,
        sha256: &[u8],
    ) -> anyhow::Result<Vec<ChannelId>> {
        let rows = sqlx::query!(
            r#"SELECT DISTINCT m.channel_id AS "channel_id!: ChannelId"
               FROM message_attachments ma
               JOIN messages m ON m.id = ma.message_id
               WHERE ma.sha256 = ? AND m.deleted_at IS NULL
               UNION
               SELECT DISTINCT co.channel_id AS "channel_id!: ChannelId"
               FROM canvas_object_attachments coa
               JOIN canvas_objects co ON co.id = coa.object_id
               WHERE coa.sha256 = ?"#,
            sha256,
            sha256
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|r| r.channel_id).collect())
    }

    /// Whether `user_id` uploaded `sha256` themselves, recorded in
    /// `attachment_uploaders`. The fetch handler uses this so someone can
    /// preview an attachment they just uploaded but have not yet put on a
    /// message - a GIF staged in the composer, most visibly - which
    /// [`may_link`] already lets them attach. The two must agree: the send
    /// path allowing what the fetch path refuses is exactly the mismatch that
    /// made a picked GIF fail to stage. Leaks nothing an uploader does not
    /// already have; a non-uploader still falls to the channel-reference
    /// check.
    pub async fn is_attachment_uploader(
        &self,
        user_id: UserId,
        sha256: &[u8],
    ) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM attachment_uploaders
               WHERE sha256 = ? AND uploaded_by = ?"#,
            sha256,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// Whether `user_id` could fetch `sha256` right now: they uploaded it, or
    /// can view a channel that has it attached. The same rule as the fetch route.
    pub async fn can_fetch_attachment(
        &self,
        user_id: UserId,
        sha256: &[u8],
    ) -> anyhow::Result<bool> {
        if self.is_attachment_uploader(user_id, sha256).await? {
            return Ok(true);
        }
        let channels = self.channels_referencing_attachment(sha256).await?;
        let perms = self.permissions_in_channels(user_id, &channels).await?;
        Ok(perms
            .values()
            .any(|p| p.contains(Permissions::VIEW_CHANNEL)))
    }

    /// Attachment summaries for a page of messages, in one query, ordered by
    /// the position they were sent with. Mirrors
    /// `Store::reactions_for_messages`: a message with no attachments is
    /// simply absent from the result rather than given an empty entry.
    pub async fn attachments_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, Vec<AttachmentSummary>)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }

        // Built rather than a fixed `query!` because the id list is variable
        // length and SQLite has no array binding.
        let mut builder = QueryBuilder::new(
            "SELECT ma.message_id, a.sha256, COALESCE(ma.filename, a.filename) AS filename, \
                    a.content_type, a.size \
             FROM message_attachments ma \
             JOIN attachments a ON a.sha256 = ma.sha256 \
             WHERE ma.message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(") ORDER BY ma.message_id, ma.position ASC");

        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut grouped: Vec<(MessageId, Vec<AttachmentSummary>)> = Vec::new();
        for row in rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let sha256: Vec<u8> = row.try_get("sha256")?;
            let summary = AttachmentSummary {
                id: crate::media::to_hex(&sha256),
                filename: row.try_get("filename")?,
                content_type: row.try_get("content_type")?,
                size: row.try_get("size")?,
            };
            match grouped.iter_mut().find(|(id, _)| *id == message_id) {
                Some((_, list)) => list.push(summary),
                None => grouped.push((message_id, vec![summary])),
            }
        }
        Ok(grouped)
    }

    /// Deletes up to a bounded batch of attachment rows uploaded more than a
    /// day ago that no message ever attached, returning their hex ids so the
    /// caller can delete the backing files (a filesystem operation, kept
    /// outside this transaction).
    ///
    /// One statement: the `NOT EXISTS` clauses are evaluated as the delete
    /// itself runs, so nothing that gets linked between being selected as a
    /// candidate and being deleted is at risk, and `RETURNING` reports
    /// exactly the rows this call actually removed rather than the wider
    /// candidate set the inner `SELECT` considered.
    ///
    /// A message is not the only thing that can point at an attachment: a
    /// custom emoji's image is an `attachments` row nothing ever attached to
    /// a message, which is the exact shape this hunts, and a canvas placement
    /// is the same shape again - a pasted image is never attached to a
    /// message at all.
    /// `0016_custom_emoji.sql` guards those bytes with `ON DELETE RESTRICT`,
    /// and RESTRICT does not filter, it aborts the whole statement. Excluding
    /// them here is what keeps one emoji from stopping the sweep for the
    /// entire deployment; the RESTRICT stays as the backstop it always was.
    /// `canvas_object_attachments` carries no such RESTRICT (see its own
    /// migration), so excluding it here is not a backstop, it is the only
    /// thing standing between a pasted image and the sweep reclaiming it out
    /// from under a still-live canvas object.
    pub async fn sweep_orphaned_attachments(&self) -> anyhow::Result<Vec<String>> {
        let cutoff = now_ms() - ORPHAN_GRACE_MS;
        let sql = format!(
            "DELETE FROM attachments WHERE sha256 IN (
                 SELECT a.sha256 FROM attachments a
                 WHERE a.created_at < ? AND NOT ({}) LIMIT ?
             ) RETURNING sha256",
            held_sql("a.sha256")
        );
        let rows: Vec<Vec<u8>> = sqlx::query_scalar(&sql)
            .bind(cutoff)
            .bind(ORPHAN_SWEEP_BATCH)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows
            .into_iter()
            .map(|sha256| crate::media::to_hex(&sha256))
            .collect())
    }

    /// Bytes currently held in stored attachments, custom emoji included, since
    /// both are rows in this table.
    ///
    /// Summed rather than tracked in a counter: a counter is a second source of
    /// truth the orphan sweep, account deletion and every failed write would
    /// each have to remember to keep in step, and the table this scans is
    /// bounded by the very ceiling the sum is checked against.
    pub async fn total_attachment_bytes(&self) -> anyhow::Result<i64> {
        let total = sqlx::query_scalar!(
            r#"SELECT COALESCE(SUM(size), 0) AS "total!: i64" FROM attachments"#
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(total)
    }
}

/// Links already-uploaded attachments to a message inside the caller's
/// transaction, in the order given (recorded as `position`). `pub(super)`
/// like `invites::spend_invite`: composed into `Store::send_message`'s own
/// transaction rather than exposed as its own `Store` method, since it only
/// ever makes sense as part of that larger write.
///
/// The link carries the name its author gave these bytes when they uploaded
/// them, falling back to the blob's first name when they have none recorded.
///
/// Authorization is [`may_link`]'s job and runs before the write lock is
/// taken; this is the existence half only.
///
/// The existence check and the insert are one statement
/// (`INSERT ... SELECT ... WHERE EXISTS`), so there is no separate
/// check-then-insert race window: either the attachment row exists at the
/// instant this runs and the link is created, or it does not and nothing is.
pub(super) async fn link_attachments(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    message_id: MessageId,
    author_id: UserId,
    sha256_list: &[Vec<u8>],
) -> Result<(), LinkError> {
    for (position, sha256) in sha256_list.iter().enumerate() {
        let position = position as i64;
        let affected = sqlx::query!(
            "INSERT INTO message_attachments (message_id, sha256, position, filename)
             SELECT ?, ?, ?, (SELECT filename FROM attachment_uploaders
                              WHERE sha256 = ? AND uploaded_by = ?)
             WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)",
            message_id,
            sha256,
            position,
            sha256,
            author_id,
            sha256
        )
        .execute(&mut **tx)
        .await?
        .rows_affected();
        if affected == 0 {
            return Err(LinkError::NotFound);
        }
    }
    Ok(())
}

/// Whether `author_id` may attach `sha256` to a message: they uploaded it
/// themselves, or they can currently view some channel that already has it.
///
/// Existence alone used to be the whole check, which let anyone who learned an
/// attachment id (the content's own sha256) attach that content to a message in
/// any channel they could post in, uploaded or not, viewable or not. The common
/// case - the sender uploaded their own file - is one `EXISTS` against
/// `attachment_uploaders`. A miss falls back to the same shape
/// `http/attachments.rs`'s fetch handler already uses: any channel that still
/// has a live message referencing these bytes, checked for VIEW_CHANNEL, which
/// is what lets forwarding something you can already see keep working.
///
/// Returns a plain `bool` on purpose. A refusal has to be indistinguishable
/// from "never uploaded", or the oracle this closes simply moves into whatever
/// maps a richer error to a status, so there is nothing more specific here for a
/// caller to leak.
///
/// Called by [`Store::send_message`] *before* it takes the write lock, never
/// from inside the transaction. Every read in that transaction runs on `tx`
/// deliberately (see that function's own note on BEGIN IMMEDIATE); reaching the
/// pool for a second connection while holding the writer is how eight
/// concurrent sends stall each other on an eight-connection pool. The residual
/// is a caller whose view access is revoked between this check and the insert
/// microseconds later, which is not an escalation: they held it when they
/// started the send.
pub(super) async fn may_link(
    store: &Store,
    author_id: UserId,
    sha256: &[u8],
) -> Result<bool, LinkError> {
    Ok(store.can_fetch_attachment(author_id, sha256).await?)
}

/// Removes a message's attachment links, returning the hex ids of any
/// attachment that is now referenced by nothing else so the caller can
/// delete the backing file after this transaction commits. The `attachments`
/// row itself is removed here, in the same transaction, so a concurrent
/// fetch can never observe a metadata row with no message ever pointing to
/// it again.
pub(super) async fn release_message_attachments(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    message_id: MessageId,
) -> Result<Vec<String>, sqlx::Error> {
    let linked = sqlx::query!(
        r#"SELECT sha256 AS "sha256!: Vec<u8>" FROM message_attachments WHERE message_id = ?"#,
        message_id
    )
    .fetch_all(&mut **tx)
    .await?;

    sqlx::query!(
        "DELETE FROM message_attachments WHERE message_id = ?",
        message_id
    )
    .execute(&mut **tx)
    .await?;

    let mut freed = Vec::new();
    for row in linked {
        let still_referenced =
            is_referenced(tx, &row.sha256, &[message_id], now_ms() - ORPHAN_GRACE_MS).await?;
        if still_referenced {
            continue;
        }
        sqlx::query!("DELETE FROM attachments WHERE sha256 = ?", row.sha256)
            .execute(&mut **tx)
            .await?;
        freed.push(crate::media::to_hex(&row.sha256));
    }
    Ok(freed)
}
