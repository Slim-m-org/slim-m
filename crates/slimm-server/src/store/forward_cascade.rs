// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What happens to the forwarded copies of a message that is going away.
//!
//! A copy is a snapshot of someone else's content, so it goes with the
//! original - but the forwarder's own words do not. A copy with nothing of
//! its own is soft-deleted like any message. One with a note or attachments
//! keeps the message and loses only the snapshot, recorded as an `edit` op so
//! live clients, cold reads and op-stream sync all learn it through paths
//! they already have.

use sqlx::{QueryBuilder, Sqlite, Transaction};

use super::attachments::release_message_attachments;
use super::message_ops::insert_message_op;
use super::{Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

/// Bounds one lookup's bound-variable count, well under SQLite's limit.
const ORIGIN_CHUNK: usize = 500;
/// Bounds one backfill transaction; each copy costs an op insert.
const BACKFILL_BATCH: i64 = 200;

/// A live copy of a message that is going away.
#[derive(Debug, Clone, Copy)]
pub(super) struct Copy {
    pub message_id: MessageId,
    pub channel_id: ChannelId,
    /// The forwarder wrote something of their own alongside the forward.
    pub has_note: bool,
}

/// A copy removed with its original, with what the caller must publish once
/// the transaction has committed.
#[derive(Debug, Clone)]
pub struct CascadedDeletion {
    pub channel_id: ChannelId,
    pub message_id: MessageId,
    pub op_seq: i64,
    pub was_pinned: bool,
    pub freed_attachments: Vec<String>,
}

/// A copy that kept the forwarder's note and lost only its snapshot.
#[derive(Debug, Clone, Copy)]
pub struct DetachedForward {
    pub channel_id: ChannelId,
    pub message_id: MessageId,
    pub op_seq: i64,
}

/// Everything one delete did to the copies of what it deleted.
#[derive(Debug, Default, Clone)]
pub struct ForwardCascade {
    pub deleted: Vec<CascadedDeletion>,
    pub detached: Vec<DetachedForward>,
}

/// `CROSS JOIN` keeps the forwards table as the outer loop; without statistics SQLite walks every live message instead.
const COPY_COLUMNS: &str = "SELECT m.id, m.channel_id, \
    (TRIM(m.content) <> '' OR EXISTS \
        (SELECT 1 FROM message_attachments a WHERE a.message_id = m.id)) AS has_note \
    FROM message_forwards f CROSS JOIN messages m ON m.id = f.message_id ";

fn copy_from(row: &sqlx::sqlite::SqliteRow) -> Result<Copy, sqlx::Error> {
    use sqlx::Row;
    Ok(Copy {
        message_id: row.try_get("id")?,
        channel_id: row.try_get("channel_id")?,
        has_note: row.try_get("has_note")?,
    })
}

/// Live copies of any of `origins` whose snapshot has not been removed yet.
pub(super) async fn live_copies_of(
    tx: &mut Transaction<'_, Sqlite>,
    origins: &[MessageId],
) -> Result<Vec<Copy>, sqlx::Error> {
    let mut copies = Vec::new();
    for chunk in origins.chunks(ORIGIN_CHUNK) {
        let mut query = QueryBuilder::new(COPY_COLUMNS);
        query.push(
            "WHERE m.deleted_at IS NULL AND f.origin_removed_at IS NULL \
             AND f.origin_message_id IN (",
        );
        let mut separated = query.separated(", ");
        for id in chunk {
            separated.push_bind(*id);
        }
        query.push(")");
        for row in query.build().fetch_all(&mut **tx).await? {
            copies.push(copy_from(&row)?);
        }
    }
    Ok(copies)
}

/// Copies whose original is already gone but which were never dealt with,
/// left over when a sweep tick hit its cap.
pub(super) async fn orphaned_copies(
    tx: &mut Transaction<'_, Sqlite>,
    limit: i64,
) -> Result<Vec<Copy>, sqlx::Error> {
    let mut query = QueryBuilder::new(COPY_COLUMNS);
    query.push(
        "JOIN messages o ON o.id = f.origin_message_id \
         WHERE m.deleted_at IS NULL AND f.origin_removed_at IS NULL \
         AND o.deleted_at IS NOT NULL LIMIT ",
    );
    query.push_bind(limit);
    query
        .build()
        .fetch_all(&mut **tx)
        .await?
        .iter()
        .map(copy_from)
        .collect()
}

/// Blanks the snapshot on a copy that keeps its note, and writes the `edit`
/// op that carries the change to everyone else.
pub(super) async fn detach_forward(
    tx: &mut Transaction<'_, Sqlite>,
    copy: &Copy,
    actor_id: Option<UserId>,
    now: i64,
) -> Result<DetachedForward, sqlx::Error> {
    sqlx::query!(
        "UPDATE message_forwards
         SET origin_removed_at = ?, origin_content = '', origin_author_id = NULL
         WHERE message_id = ?",
        now,
        copy.message_id
    )
    .execute(&mut **tx)
    .await?;
    let op_seq =
        insert_message_op(tx, copy.channel_id, copy.message_id, "edit", actor_id, now).await?;
    Ok(DetachedForward {
        channel_id: copy.channel_id,
        message_id: copy.message_id,
        op_seq,
    })
}

/// Soft-deletes one copy that has nothing of its own, mirroring what
/// `Store::delete_message` does for one message.
async fn delete_copy(
    tx: &mut Transaction<'_, Sqlite>,
    copy: &Copy,
    actor_id: Option<UserId>,
    now: i64,
) -> Result<Option<CascadedDeletion>, sqlx::Error> {
    let message_id = copy.message_id;
    let was_pinned = sqlx::query_scalar!(
        r#"SELECT EXISTS(SELECT 1 FROM pinned_messages WHERE message_id = ?) AS "p!: bool""#,
        message_id
    )
    .fetch_one(&mut **tx)
    .await?;
    let claimed = sqlx::query!(
        "UPDATE messages SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
        now,
        message_id
    )
    .execute(&mut **tx)
    .await?
    .rows_affected();
    if claimed == 0 {
        return Ok(None);
    }
    let op_seq =
        insert_message_op(tx, copy.channel_id, message_id, "delete", actor_id, now).await?;
    Ok(Some(CascadedDeletion {
        channel_id: copy.channel_id,
        message_id,
        op_seq,
        was_pinned,
        freed_attachments: release_message_attachments(tx, message_id).await?,
    }))
}

/// Deals with each of `copies`, inside the caller's transaction.
async fn apply_to_copies(
    tx: &mut Transaction<'_, Sqlite>,
    copies: &[Copy],
    actor_id: Option<UserId>,
    now: i64,
) -> Result<ForwardCascade, sqlx::Error> {
    let mut cascade = ForwardCascade::default();
    for copy in copies {
        if copy.has_note {
            cascade
                .detached
                .push(detach_forward(tx, copy, actor_id, now).await?);
        } else if let Some(gone) = delete_copy(tx, copy, actor_id, now).await? {
            cascade.deleted.push(gone);
        }
    }
    Ok(cascade)
}

/// Deals with every live copy of `origins` inside the caller's transaction.
pub(super) async fn cascade_to_copies(
    tx: &mut Transaction<'_, Sqlite>,
    origins: &[MessageId],
    actor_id: Option<UserId>,
    now: i64,
) -> Result<ForwardCascade, sqlx::Error> {
    let copies = live_copies_of(tx, origins).await?;
    apply_to_copies(tx, &copies, actor_id, now).await
}

impl Store {
    /// Deals with every copy whose original was deleted before copies followed
    /// their originals, in bounded batches so the write lock is never held long.
    ///
    /// Idempotent: a handled copy is deleted or marked removed, so it no longer
    /// matches and a second run finds nothing. Publishes nothing; the ops it
    /// writes reach clients through sync.
    pub async fn backfill_orphaned_forwards(&self) -> anyhow::Result<ForwardCascade> {
        let mut total = ForwardCascade::default();
        loop {
            let mut tx = self.begin_write().await?;
            let copies = orphaned_copies(&mut tx, BACKFILL_BATCH).await?;
            let batch = apply_to_copies(&mut tx, &copies, None, now_ms()).await?;
            tx.commit().await?;
            if batch.deleted.is_empty() && batch.detached.is_empty() {
                return Ok(total);
            }
            total.deleted.extend(batch.deleted);
            total.detached.extend(batch.detached);
        }
    }
}
