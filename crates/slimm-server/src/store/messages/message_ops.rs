// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message op stream: how an edit or a delete reaches a client that was
//! offline when it happened.
//!
//! `messages.seq` is allocated once, at creation, and never moves again, so a
//! cursor over it can only ever report messages that did not exist last time.
//! An edit changes content in place and a delete sets `deleted_at`, and
//! neither is visible to a `seq > cursor` read at any later point. This is a
//! second, independent sequence over the same channel, dense over the ops it
//! carries, which is what lets a client treat `n + 1` as the very next op that
//! exists rather than as a guess.
//!
//! Density is the whole property, and it holds because every real mutation
//! allocates exactly one seq and writes exactly one row in the same
//! transaction. A mutation that changes nothing writes no row and allocates
//! no seq, which is why [`super::super::Store::edit_message`] answers three ways
//! rather than two.

use sqlx::{Sqlite, Transaction};

use super::super::Store;
use crate::ids::{ChannelId, MessageId, UserId};

/// One page of a channel's message op stream, with the head it was read
/// against. Both come from one snapshot, which is what lets a caller trust
/// `latest_seq` as the end of what this page could have covered.
#[derive(Debug, Clone)]
pub struct MessageOpsPage {
    pub ops: Vec<MessageOpEntry>,
    /// The highest op seq allocated for the channel, 0 where none has been.
    pub latest_seq: i64,
}

/// One entry in a channel's message op stream.
#[derive(Debug, Clone)]
pub struct MessageOpEntry {
    pub seq: i64,
    pub message_id: MessageId,
    pub kind: MessageOpKind,
    /// Who performed it, null once their account has been anonymised. The
    /// moderation record: this is the only place anything records who deleted
    /// a message, and it is deliberately never put on the wire, matching what
    /// `Event::MessageDeleted` already withholds from a live connection.
    pub actor_id: Option<UserId>,
    pub created_at: i64,
    /// The message's content as it stands now, joined at read time rather
    /// than stored on the op. Absent on a `delete`, and absent on an `edit`
    /// whose message has since been deleted: a later `delete` op in the same
    /// stream is what the client acts on instead.
    pub content: Option<String>,
    pub edited_at: Option<i64>,
    /// The message is a forward whose original has since been removed, joined
    /// at read time like `content`. Only ever true on an `edit`.
    pub forwarded_removed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageOpKind {
    Edit,
    Delete,
}

impl MessageOpKind {
    fn from_sql(kind: &str) -> Option<Self> {
        match kind {
            "edit" => Some(Self::Edit),
            "delete" => Some(Self::Delete),
            _ => None,
        }
    }
}

/// Writes one op row under a freshly allocated `'message_op'` seq, in the
/// transaction that performed the mutation, and answers with that seq.
///
/// The counter row is upserted rather than read, so a channel created before
/// migration 0027 needs no backfill and no channel-creation path needs
/// editing. That is the whole reason 0027 writes nothing to live data, and it
/// is deliberately not the `UPDATE ... RETURNING` shape `send_message` uses:
/// that one relies on a counter row channel creation inserted, and copying it
/// here would have forced the backfill.
///
/// `actor_id` is `None` for a system-initiated act (the retention sweep, in
/// `message_retention.rs`) rather than a real caller's own edit or delete.
/// The wire already withholds this field on every kind, so a client cannot
/// tell the two apart, and that is the point: an automated prune reads no
/// differently from a moderator whose account has since been anonymised.
pub(in crate::store) async fn insert_message_op(
    tx: &mut Transaction<'_, Sqlite>,
    channel_id: ChannelId,
    message_id: MessageId,
    kind: &str,
    actor_id: Option<UserId>,
    created_at: i64,
) -> Result<i64, sqlx::Error> {
    // `2` so the first op takes seq 1, the same arithmetic the update branch gives.
    let seq = sqlx::query_scalar!(
        r#"INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
           VALUES (?, 'message_op', 2)
           ON CONFLICT(channel_id, stream) DO UPDATE SET next_seq = next_seq + 1
           RETURNING next_seq - 1 AS "seq!: i64""#,
        channel_id
    )
    .fetch_one(&mut **tx)
    .await?;

    sqlx::query!(
        r#"INSERT INTO message_ops (channel_id, seq, message_id, kind, actor_id, created_at)
           VALUES (?, ?, ?, ?, ?, ?)"#,
        channel_id,
        seq,
        message_id,
        kind,
        actor_id,
        created_at
    )
    .execute(&mut **tx)
    .await?;
    Ok(seq)
}

impl Store {
    /// Pages the message op stream from `after_seq` (exclusive), in one
    /// deferred read transaction so the page and its `latest_seq` share a
    /// snapshot, the shape [`Store::list_canvas_ops`] already uses: a write
    /// landing between the two reads cannot produce a `latest_seq` the page
    /// does not cover.
    ///
    /// Content is joined at read time, so an edit op naming a since-deleted
    /// message answers with no content rather than with text the reader is no
    /// longer allowed to see.
    pub async fn message_ops_since(
        &self,
        channel_id: ChannelId,
        after_seq: i64,
        limit: i64,
    ) -> anyhow::Result<MessageOpsPage> {
        let mut tx = self.begin_read().await?;

        let latest_seq = sqlx::query_scalar!(
            r#"SELECT next_seq - 1 AS "seq!: i64" FROM channel_seq_counters
               WHERE channel_id = ? AND stream = 'message_op'"#,
            channel_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .unwrap_or(0);

        let rows = sqlx::query!(
            r#"SELECT o.seq AS "seq!: i64", o.message_id AS "message_id!: MessageId",
                      o.kind AS "kind!", o.actor_id AS "actor_id: UserId",
                      o.created_at AS "created_at!: i64",
                      m.content AS "content?: String", m.edited_at AS "edited_at?: i64",
                      (f.origin_removed_at IS NOT NULL) AS "forwarded_removed!: bool"
               FROM message_ops o
               LEFT JOIN messages m
                 ON m.id = o.message_id AND o.kind = 'edit' AND m.deleted_at IS NULL
               LEFT JOIN message_forwards f ON f.message_id = m.id
               WHERE o.channel_id = ? AND o.seq > ?
               ORDER BY o.seq ASC
               LIMIT ?"#,
            channel_id,
            after_seq,
            limit
        )
        .fetch_all(&mut *tx)
        .await?;
        tx.commit().await?;

        let ops = rows
            .into_iter()
            .filter_map(|row| {
                Some(MessageOpEntry {
                    seq: row.seq,
                    message_id: row.message_id,
                    kind: MessageOpKind::from_sql(&row.kind)?,
                    actor_id: row.actor_id,
                    created_at: row.created_at,
                    content: row.content,
                    edited_at: row.edited_at,
                    forwarded_removed: row.forwarded_removed,
                })
            })
            .collect();
        Ok(MessageOpsPage { ops, latest_seq })
    }

    /// The highest op seq allocated for a channel, 0 where none has been.
    ///
    /// A counter read, so a scope that carries no op cursor can still be told
    /// the head to adopt without paging anything.
    pub async fn latest_message_op_seq(&self, channel_id: ChannelId) -> anyhow::Result<i64> {
        Ok(sqlx::query_scalar!(
            r#"SELECT next_seq - 1 AS "seq!: i64" FROM channel_seq_counters
               WHERE channel_id = ? AND stream = 'message_op'"#,
            channel_id
        )
        .fetch_optional(&self.pool)
        .await?
        .unwrap_or(0))
    }

    /// The lowest op seq still retained for a channel, `None` where the stream
    /// holds nothing.
    ///
    /// The floor moves: `Store::reclaim_message_ops_before` (the message
    /// retention sweep) drops ops past the cutoff, so this is the sweep's
    /// high-water mark rather than the first op ever written. It was the
    /// latter when this was added, and the reset branch depending on it was
    /// written and tested before there was a sweep to move it - see
    /// `http::sync_ops`'s `effective_floor` for the caller that reads it.
    pub async fn earliest_message_op_seq(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<i64>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT MIN(seq) AS "floor: i64" FROM message_ops WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_one(&self.pool)
        .await?)
    }
}
