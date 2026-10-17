// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Message retention: an opt-in, deployment-wide window past which a
//! message is pruned, on the same periodic-sweep model as
//! [`Store::sweep_expired_tokens`] and [`Store::sweep_canvas_ops`]. A channel
//! may override the window (`channel_retention.rs`), and whatever is left in
//! a deleted channel is pruned whatever the window, since nothing can reach it.
//!
//! A prune is an ordinary soft delete, the same shape [`Store::delete_message`]
//! already uses (`deleted_at` set, attachments released, a `message_ops`
//! `'delete'` row written) - just run in a batch, under one system actor,
//! rather than one call per caller. Content is left in place: text is small
//! next to attachment bytes, and the disk this feature actually reclaims is
//! whatever `release_message_attachments` frees.
//!
//! The half worth reading closely is what happens to the *op stream* a
//! pruned message leaves behind. `message_ops`'s own doc says a floor
//! sweep "can be added later with no wire change" - this is that sweep.
//! [`Store::reclaim_message_ops_before`] deletes `message_ops` rows older
//! than the same cutoff, which advances [`Store::earliest_message_op_seq`]'s
//! floor. A client whose op cursor now sits behind that floor gets `reset`
//! from `ops_for_scope` with no code written here at all: the mechanism
//! already existed, waiting for something to move the floor. Content pruning
//! runs first in the same tick as a matter of sequence, not because order is
//! load-bearing here: the delete op a fresh prune just wrote carries `now`,
//! and `cutoff` sits a whole retention window behind it, so no ordering of
//! these two passes could make the reclaim treat that op as stale.

use std::collections::HashMap;

use sqlx::QueryBuilder;

use super::super::attachments::ORPHAN_GRACE_MS;
use super::super::attachments::refs::is_referenced;
use super::super::forward_cascade::{
    Copy, DetachedForward, detach_forward, live_copies_of, orphaned_copies,
};
use super::super::{Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Bounds how long the content-pruning pass can hold the write lock: each
/// row costs an op insert and an attachment release, so this is smaller than
/// [`OP_FLOOR_SWEEP_BATCH`], whose rows are one bare `DELETE` each.
const CONTENT_SWEEP_BATCH: i64 = 200;
/// Bounds how many forwarded copies one batch pulls in with its originals, so
/// the batch's bound-variable count stays far under SQLite's limit; the rest
/// are found as orphans on the next tick.
const COPY_SWEEP_CAP: usize = 2_000;
/// Bounds the op-log reclaim pass.
const OP_FLOOR_SWEEP_BATCH: i64 = 2_000;
/// How many content batches one tick may run, each in its own transaction so
/// the write lock is released between them: 50 batches is 10,000 messages a
/// tick, past which the rest wait six hours rather than stall writers.
const SWEEP_BATCHES_PER_TICK: usize = 50;

/// The largest window a caller may set, ten years. Not a real ceiling on
/// retained history - a deployment's own disk is whatever it is under
/// that - only a guard against a typo landing as an effectively-unbounded
/// value with nothing to say so.
pub const MAX_MESSAGE_RETENTION_DAYS: i64 = 3650;

/// One message the sweep pruned this tick.
#[derive(Debug, Clone)]
pub struct PrunedMessage {
    pub channel_id: ChannelId,
    pub message_id: MessageId,
    /// Always `Some`: every candidate this pass selects is still live, so
    /// the soft delete it performs always writes a fresh op.
    pub op_seq: Option<i64>,
    pub freed_attachments: Vec<String>,
    /// Whether it was pinned. The soft delete's trigger drops the pin row, so
    /// the sweep must announce the unpin itself or clients keep showing it.
    pub was_pinned: bool,
}

/// What one retention sweep tick did.
#[derive(Debug, Default)]
pub struct SweptMessageRetention {
    pub pruned: Vec<PrunedMessage>,
    /// Forwarded copies that kept the forwarder's note and lost only the snapshot.
    pub detached: Vec<DetachedForward>,
    /// Stale `message_ops` rows the same tick reclaimed; see the module doc.
    pub ops_reclaimed: u64,
}

impl Store {
    /// The current retention window in days. `0` means disabled - keep
    /// forever - the default, and what every deployment that predates this
    /// setting keeps on upgrade.
    pub async fn message_retention_days(&self) -> anyhow::Result<i64> {
        let value = sqlx::query_scalar!(
            r#"SELECT message_retention_days AS "d!: i64" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(value.unwrap_or(0))
    }

    /// How many live messages a window of `days` would prune if it applied
    /// now, so an admin can see the cost before shortening it. `0` (keep
    /// forever) prunes nothing.
    pub async fn count_messages_past_retention(&self, days: i64) -> anyhow::Result<i64> {
        if days <= 0 {
            return Ok(0);
        }
        let cutoff = now_ms() - days * DAY_MS;
        // A channel with its own window (or a thread under one) is not the Space's to prune.
        let count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM messages m
               JOIN channels c ON c.id = m.channel_id
               LEFT JOIN messages pm ON pm.id = c.parent_message_id
               LEFT JOIN channel_retention cr ON cr.channel_id = COALESCE(pm.channel_id, c.id)
               WHERE m.deleted_at IS NULL AND m.created_at < ? AND cr.channel_id IS NULL"#,
            cutoff
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    /// Sets the retention window. Callers validate `days` against
    /// [`MAX_MESSAGE_RETENTION_DAYS`] and non-negativity before reaching
    /// here; the column's own `CHECK` is the backstop.
    pub async fn set_message_retention_days(&self, days: i64) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings SET message_retention_days = ?, updated_at = ? WHERE id = 1",
            days,
            now
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// One sweep tick: prunes every message past its channel's window (the
    /// channel's own, a thread's parent's, else the Space's) and everything
    /// left in a deleted channel, a batch at a time until none remain or
    /// [`SWEEP_BATCHES_PER_TICK`] is reached, so a newly shortened window
    /// lands within the tick the admin was told about rather than over days.
    pub async fn sweep_message_retention(&self) -> anyhow::Result<SweptMessageRetention> {
        let space_days = self.message_retention_days().await?;
        let mut swept = SweptMessageRetention::default();
        for _ in 0..SWEEP_BATCHES_PER_TICK {
            let (pruned, detached) = self.prune_expired_messages(space_days).await?;
            let done = pruned.is_empty() && detached.is_empty();
            swept.pruned.extend(pruned);
            swept.detached.extend(detached);
            if done {
                break;
            }
        }
        if space_days > 0 {
            let cutoff = now_ms() - space_days * DAY_MS;
            swept.ops_reclaimed = self.reclaim_message_ops_before(cutoff).await?;
        }
        Ok(swept)
    }

    /// Soft-deletes up to [`CONTENT_SWEEP_BATCH`] live messages older than
    /// `cutoff`, oldest first, each ending in exactly the state
    /// [`Store::delete_message`] leaves - `deleted_at` set, a `delete` op
    /// written, attachments released - under one system actor
    /// (`actor_id: None`), but batched rather than per message so the write
    /// lock is held across a handful of round trips instead of one per
    /// message; see SRV2.
    async fn prune_expired_messages(
        &self,
        space_days: i64,
    ) -> anyhow::Result<(Vec<PrunedMessage>, Vec<DetachedForward>)> {
        use sqlx::Row;

        let mut tx = self.begin_write().await?;
        let now = now_ms();
        // A deleted channel has no way back, so what is left in it (and its threads) only holds disk.
        let candidates = sqlx::query_scalar!(
            r#"SELECT m.id AS "id!: MessageId" FROM messages m
               JOIN channels c ON c.id = m.channel_id
               LEFT JOIN messages pm ON pm.id = c.parent_message_id
               LEFT JOIN channels p ON p.id = pm.channel_id
               LEFT JOIN channel_retention cr ON cr.channel_id = COALESCE(p.id, c.id)
               WHERE m.deleted_at IS NULL
                 AND (c.deleted_at IS NOT NULL
                      OR p.deleted_at IS NOT NULL
                      OR (COALESCE(cr.retention_days, ?1) > 0
                          AND m.created_at < ?2 - COALESCE(cr.retention_days, ?1) * ?3))
               ORDER BY m.created_at ASC
               LIMIT ?4"#,
            space_days,
            now,
            DAY_MS,
            CONTENT_SWEEP_BATCH
        )
        .fetch_all(&mut *tx)
        .await?;
        let mut candidates = candidates;
        // Copies of this batch and leftovers from a capped earlier tick; those with a note are detached, the rest join the delete.
        let mut copies = live_copies_of(&mut tx, &candidates).await?;
        copies.truncate(COPY_SWEEP_CAP);
        copies.extend(orphaned_copies(&mut tx, CONTENT_SWEEP_BATCH).await?);
        let (noted, bare): (Vec<Copy>, Vec<Copy>) = copies.into_iter().partition(|c| c.has_note);
        candidates.extend(bare.iter().map(|c| c.message_id));
        candidates.sort_unstable_by_key(|id| id.0);
        candidates.dedup();
        let mut detached = Vec::new();
        for copy in noted.iter().filter(|c| !candidates.contains(&c.message_id)) {
            if detached
                .iter()
                .all(|d: &DetachedForward| d.message_id != copy.message_id)
            {
                detached.push(detach_forward(&mut tx, copy, None, now).await?);
            }
        }
        if candidates.is_empty() {
            tx.commit().await?;
            return Ok((Vec::new(), detached));
        }

        // Read before the soft delete fires the trigger that drops the pin; see `PrunedMessage::was_pinned`.
        let mut pinned_query =
            QueryBuilder::new("SELECT message_id FROM pinned_messages WHERE message_id IN (");
        let mut pinned_ids = pinned_query.separated(", ");
        for id in &candidates {
            pinned_ids.push_bind(*id);
        }
        pinned_query.push(")");
        let pinned: std::collections::HashSet<MessageId> = pinned_query
            .build_query_scalar::<MessageId>()
            .fetch_all(&mut *tx)
            .await?
            .into_iter()
            .collect();

        // One soft-delete for the whole batch; RETURNING names the rows it actually flipped and their channel.
        let mut update = QueryBuilder::new("UPDATE messages SET deleted_at = ");
        update.push_bind(now);
        update.push(" WHERE deleted_at IS NULL AND id IN (");
        let mut separated = update.separated(", ");
        for id in &candidates {
            separated.push_bind(*id);
        }
        update.push(") RETURNING id, channel_id");
        let channel_of: HashMap<MessageId, ChannelId> = update
            .build()
            .fetch_all(&mut *tx)
            .await?
            .iter()
            .map(|row| Ok((row.try_get("id")?, row.try_get("channel_id")?)))
            .collect::<Result<_, sqlx::Error>>()?;
        if channel_of.is_empty() {
            tx.commit().await?;
            return Ok((Vec::new(), detached));
        }

        // Candidate (created_at ASC) order, restricted to what was really deleted, so seqs land in that order.
        let ordered: Vec<(MessageId, ChannelId)> = candidates
            .iter()
            .filter_map(|id| channel_of.get(id).map(|channel| (*id, *channel)))
            .collect();

        // One dense seq run per channel: bump each counter once by its count, then hand the run out in order.
        let mut count_per_channel: HashMap<ChannelId, i64> = HashMap::new();
        for (_, channel) in &ordered {
            *count_per_channel.entry(*channel).or_default() += 1;
        }
        let mut next_seq: HashMap<ChannelId, i64> = HashMap::new();
        for (channel, count) in &count_per_channel {
            let count = *count;
            // Seeds a fresh counter at count + 1 so the first seq is 1, as insert_message_op's VALUES(...,2) does for one.
            let seed = count + 1;
            let advanced = sqlx::query_scalar!(
                r#"INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
                   VALUES (?, 'message_op', ?)
                   ON CONFLICT(channel_id, stream) DO UPDATE SET next_seq = next_seq + ?
                   RETURNING next_seq AS "next_seq!: i64""#,
                channel,
                seed,
                count
            )
            .fetch_one(&mut *tx)
            .await?;
            next_seq.insert(*channel, advanced - count);
        }
        let mut op_seq_of: HashMap<MessageId, i64> = HashMap::new();
        for (message_id, channel) in &ordered {
            let seq = next_seq.get_mut(channel).expect("counted above");
            op_seq_of.insert(*message_id, *seq);
            *seq += 1;
        }

        // One multi-row op insert; each row carries its own seq, so insertion order does not matter.
        let mut ops = QueryBuilder::new(
            "INSERT INTO message_ops (channel_id, seq, message_id, kind, actor_id, created_at) ",
        );
        ops.push_values(&ordered, |mut row, (message_id, channel)| {
            row.push_bind(*channel)
                .push_bind(op_seq_of[message_id])
                .push_bind(*message_id)
                .push_bind("delete")
                .push_bind(None::<UserId>)
                .push_bind(now);
        });
        ops.build().execute(&mut *tx).await?;

        // One attachment release for the whole batch.
        let message_ids: Vec<MessageId> = ordered.iter().map(|(id, _)| *id).collect();
        let mut freed_of: HashMap<MessageId, Vec<String>> = HashMap::new();
        for (message_id, hex) in release_message_attachments_batch(&mut tx, &message_ids).await? {
            freed_of.entry(message_id).or_default().push(hex);
        }

        tx.commit().await?;

        let pruned = ordered
            .into_iter()
            .map(|(message_id, channel_id)| PrunedMessage {
                channel_id,
                message_id,
                op_seq: Some(op_seq_of[&message_id]),
                freed_attachments: freed_of.remove(&message_id).unwrap_or_default(),
                was_pinned: pinned.contains(&message_id),
            })
            .collect();
        Ok((pruned, detached))
    }

    /// Deletes up to [`OP_FLOOR_SWEEP_BATCH`] `message_ops` rows older than
    /// `cutoff`, advancing the floor for every channel with one. One
    /// statement, so no `begin_write` is needed - see `canvas_ops_sweep.rs`
    /// for the same reasoning on its own single-statement passes.
    async fn reclaim_message_ops_before(&self, cutoff: i64) -> anyhow::Result<u64> {
        let reclaimed = sqlx::query!(
            r#"DELETE FROM message_ops WHERE (channel_id, seq) IN (
                   SELECT channel_id, seq FROM message_ops WHERE created_at < ? LIMIT ?
               )"#,
            cutoff,
            OP_FLOOR_SWEEP_BATCH
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(reclaimed)
    }
}

/// Unlinks a batch of messages' attachments in one pass and reports each freed
/// hex once, the batched form of `attachments::release_message_attachments`
/// the prune above needs. Lives here rather than there so that file stays
/// under its ceiling; the single-message path remains its owner.
///
/// A sha256 is freed when nothing outside this batch still references it - a
/// live message not being pruned, a custom emoji, or a canvas object - the
/// single path's exact final state, reached by deleting every link in the
/// batch first and only then testing each distinct sha256. Each freed hex is
/// reported once,
/// attributed to one of the messages that linked it; which one does not
/// matter, since the caller only uses the set to delete files.
async fn release_message_attachments_batch(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    message_ids: &[MessageId],
) -> Result<Vec<(MessageId, String)>, sqlx::Error> {
    use std::collections::HashSet;

    use sqlx::Row;

    if message_ids.is_empty() {
        return Ok(Vec::new());
    }

    let mut select = QueryBuilder::new(
        "SELECT message_id, sha256 FROM message_attachments WHERE message_id IN (",
    );
    let mut separated = select.separated(", ");
    for id in message_ids {
        separated.push_bind(*id);
    }
    select.push(")");
    let rows = select.build().fetch_all(&mut **tx).await?;
    let links: Vec<(MessageId, Vec<u8>)> = rows
        .iter()
        .map(|row| Ok((row.try_get("message_id")?, row.try_get("sha256")?)))
        .collect::<Result<_, sqlx::Error>>()?;

    let mut delete = QueryBuilder::new("DELETE FROM message_attachments WHERE message_id IN (");
    let mut separated = delete.separated(", ");
    for id in message_ids {
        separated.push_bind(*id);
    }
    delete.push(")");
    delete.build().execute(&mut **tx).await?;

    let mut freed = Vec::new();
    let mut checked: HashSet<Vec<u8>> = HashSet::new();
    for (message_id, sha256) in &links {
        // Each distinct sha256 tested once; a later duplicate link is skipped.
        if !checked.insert(sha256.clone()) {
            continue;
        }
        let linking: Vec<MessageId> = links
            .iter()
            .filter(|(_, linked)| linked == sha256)
            .map(|(id, _)| *id)
            .collect();
        let still_referenced =
            is_referenced(tx, sha256, &linking, now_ms() - ORPHAN_GRACE_MS).await?;
        if still_referenced {
            continue;
        }
        sqlx::query!("DELETE FROM attachments WHERE sha256 = ?", sha256)
            .execute(&mut **tx)
            .await?;
        freed.push((*message_id, crate::media::to_hex(sha256)));
    }
    Ok(freed)
}
