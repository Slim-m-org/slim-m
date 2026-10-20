// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas op stream: the single ordering authority every canvas mutation
//! writes into, and the paged catch-up feed a client reads it back through.
//!
//! Every mutation, so far only [`super::Store::place_canvas_object`],
//! allocates one seq from the channel's `canvas` counter and writes exactly
//! one row here in the same transaction. That is what makes the sequence
//! dense over ops rather than a high-water mark over a sparse space: a client
//! that has consumed up to `n` may treat `n + 1` as the very next op that
//! exists, with no possibility of an allocated-but-unwritten hole.

use std::collections::HashMap;

use anyhow::Context;

use super::super::Store;
use super::CanvasObject;
use super::canvas_ops_write::ClearScope;
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId, Seq, UserId};

/// Past this many ops behind, replaying the feed is no cheaper than a cold
/// viewport re-read, and the re-read is strictly better because it also drops
/// everything outside the caller's region. Set equal to the viewport read's
/// own `MAX_LIMIT`.
pub const CANVAS_OP_GAP: i64 = 2_000;

/// Stops a page early once the accumulated `place` props, plus an estimate
/// of every other kind's own `canvas_op_targets` rows, cross this many bytes.
/// A page bounded only by row count still varies three orders of magnitude,
/// since a `place` op carries whole props at up to `MAX_PROPS_BYTES` (4 KiB)
/// while `remove` is capped at `MAX_REMOVE_IDS_PER_OP` (64) ids - but
/// `restore` is not: undoing a large `clear` can un-delete up to
/// `MAX_OBJECTS_PER_CHANNEL` objects in one op, and a page bounded only by
/// row count could gang up to `MAX_LIMIT` of those into one response with no
/// byte ceiling at all. `list_canvas_ops` counts a `canvas_op_targets` row
/// toward this budget at [`CANVAS_OP_TARGET_BYTES_ESTIMATE`] apiece for
/// exactly that reason.
///
/// A single restore still may exceed this alone, same as `place` could if
/// `MAX_PROPS_BYTES` were raised past it: the first row of a page is always
/// admitted regardless of its own size, or a client parked behind one
/// oversized op could never advance past it - the same livelock
/// `message_ops`'s own sync gate refuses to risk. What this budget now stops
/// is several such ops compounding in one page; each lands in its own,
/// bounded page instead. See `tests/canvas_ops/feed.rs`.
pub const CANVAS_OP_PAGE_BYTES: usize = 512 * 1024;

/// A rough per-id wire cost for a `canvas_op_targets` row once serialized
/// into a `remove` or `restore` body's `object_ids` array: a UUID's 36
/// characters, its surrounding quotes, and a separating comma, rounded up.
/// Deliberately approximate - the budget only needs to bound a page, not
/// account for it to the byte.
const CANVAS_OP_TARGET_BYTES_ESTIMATE: usize = 40;

/// One page of the ops feed.
#[derive(Debug)]
pub struct CanvasOpsPage {
    pub ops: Vec<CanvasOpEntry>,
    pub latest_seq: i64,
    pub has_more: bool,
    /// The cursor was too far behind, or ahead (after a Litestream restore),
    /// to page correctly. `ops` is always empty alongside this; discard local
    /// state and cold-fetch instead of trusting a partial answer.
    pub reset: bool,
}

/// One row of the ops feed: the fields every kind shares, plus its body.
#[derive(Debug)]
pub struct CanvasOpEntry {
    pub seq: i64,
    pub id: CanvasOpId,
    /// Null once the actor's account has been anonymized.
    pub actor_id: Option<UserId>,
    pub created_at: i64,
    pub body: CanvasOpBody,
}

/// The kind-specific part of one op, which is also its wire discriminant.
#[derive(Debug)]
pub enum CanvasOpBody {
    /// `None` when the placed object has since been removed: a client should
    /// not paint an object the server no longer holds live.
    Place(Option<CanvasObject>),
    Remove(Vec<CanvasObjectId>),
    Clear {
        before_seq: i64,
        scope: ClearScope,
    },
    Restore {
        target_op: CanvasOpId,
        object_ids: Vec<CanvasObjectId>,
    },
    /// An object was repositioned to `(x, y, w, h)`, without touching its
    /// `z_index`.
    Move {
        object_id: CanvasObjectId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    /// An object's paint order was set to `z_index`, without touching its
    /// bounds.
    Reorder {
        object_id: CanvasObjectId,
        z_index: i64,
    },
    Edit {
        object_id: CanvasObjectId,
        props: String,
    },
}

/// Writes the op row a placement produces, under the `seq` the object itself
/// was just given, in the transaction that allocated it.
///
/// Asserted equal to the object's own `seq` by this call site alone - there is
/// no FK or CHECK enforcing it - which is the one seam where a second
/// ordering authority could grow back into the canvas.
pub(in crate::store) async fn insert_place_op(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    seq: i64,
    actor_id: UserId,
    object_id: CanvasObjectId,
    created_at: i64,
) -> Result<(), sqlx::Error> {
    let op_id = CanvasOpId::generate();
    sqlx::query!(
        r#"INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at)
           VALUES (?, ?, ?, 'place', ?, ?)"#,
        channel_id,
        seq,
        op_id,
        actor_id,
        created_at
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO canvas_op_targets (channel_id, seq, object_id) VALUES (?, ?, ?)",
        channel_id,
        seq,
        object_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

impl Store {
    /// Pages the canvas op stream from `after_seq` (exclusive), newest bound
    /// by `limit`, in one deferred read transaction so the page and its
    /// `latest_seq` share a single snapshot: a concurrent write between the
    /// two reads cannot produce a `latest_seq` the page does not cover.
    pub async fn list_canvas_ops(
        &self,
        channel_id: ChannelId,
        after_seq: i64,
        limit: i64,
    ) -> anyhow::Result<CanvasOpsPage> {
        let mut tx = self.begin_read().await?;

        let latest_seq = sqlx::query_scalar!(
            r#"SELECT next_seq - 1 AS "seq!: i64" FROM channel_seq_counters
               WHERE channel_id = ? AND stream = 'canvas'"#,
            channel_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .unwrap_or(0);

        // NULL (no rows yet) reads as no floor, never a reason to reset a cold start at 0.
        let floor = sqlx::query_scalar!(
            r#"SELECT MIN(seq) AS "floor: i64" FROM canvas_ops WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_one(&mut *tx)
        .await?;

        let reset = after_seq > latest_seq
            || latest_seq - after_seq > CANVAS_OP_GAP
            || floor.is_some_and(|floor| after_seq < floor - 1);
        if reset {
            tx.commit().await?;
            return Ok(CanvasOpsPage {
                ops: Vec::new(),
                latest_seq,
                has_more: false,
                reset: true,
            });
        }

        let page_limit = limit + 1;
        let fetched = sqlx::query!(
            r#"SELECT o.seq AS "seq!: i64", o.id AS "id!: CanvasOpId", o.kind AS "kind!",
                      o.actor_id AS "actor_id: UserId", o.bound_seq AS "bound_seq: i64",
                      o.clear_kinds AS "clear_kinds: String", o.clear_author_id AS "clear_author_id: UserId",
                      o.target_op AS "target_op: CanvasOpId", o.created_at AS "created_at!: i64",
                      o.move_x AS "move_x: f64", o.move_y AS "move_y: f64",
                      o.move_w AS "move_w: f64", o.move_h AS "move_h: f64",
                      o.reorder_z AS "reorder_z: i64", o.edit_props AS "edit_props: String",
                      obj.id AS "obj_id?: CanvasObjectId", obj.kind AS "obj_kind?: String",
                      obj.z_index AS "obj_z_index?: i64", obj.x AS "obj_x?: f64",
                      obj.y AS "obj_y?: f64", obj.w AS "obj_w?: f64", obj.h AS "obj_h?: f64",
                      obj.props AS "obj_props?: String", obj.author_id AS "obj_author_id?: UserId",
                      obj.seq AS "obj_seq?: Seq", obj.created_at AS "obj_created_at?: i64"
               FROM canvas_ops o
               LEFT JOIN canvas_objects obj
                 ON obj.channel_id = o.channel_id AND obj.seq = o.seq
                 AND o.kind = 'place' AND obj.deleted_at IS NULL
               WHERE o.channel_id = ? AND o.seq > ?
               ORDER BY o.seq ASC
               LIMIT ?"#,
            channel_id,
            after_seq,
            page_limit
        )
        .fetch_all(&mut *tx)
        .await?;

        // Over-read by one, dropped from the back: the opposite end from the viewport read.
        let has_more_by_count = fetched.len() as i64 > limit;
        let page = if has_more_by_count {
            &fetched[..limit as usize]
        } else {
            &fetched[..]
        };

        // Counted before the budget decides what fits, or the very kinds this closes a residual for would go uncounted.
        let target_counts = if page.iter().any(|row| row.kind != "place") {
            if let (Some(first), Some(last)) = (page.first(), page.last()) {
                sqlx::query!(
                    r#"SELECT seq AS "seq!: i64", COUNT(*) AS "count!: i64"
                       FROM canvas_op_targets
                       WHERE channel_id = ? AND seq >= ? AND seq <= ?
                       GROUP BY seq"#,
                    channel_id,
                    first.seq,
                    last.seq
                )
                .fetch_all(&mut *tx)
                .await?
                .into_iter()
                .map(|row| (row.seq, row.count))
                .collect::<HashMap<i64, i64>>()
            } else {
                HashMap::new()
            }
        } else {
            HashMap::new()
        };

        let mut budget = 0usize;
        let mut included = page.len();
        for (i, row) in page.iter().enumerate() {
            let bytes = if row.kind == "place" {
                row.obj_props.as_ref().map_or(0, std::string::String::len)
            } else {
                target_counts.get(&row.seq).copied().unwrap_or(0) as usize
                    * CANVAS_OP_TARGET_BYTES_ESTIMATE
            };
            if i > 0 && budget + bytes > CANVAS_OP_PAGE_BYTES {
                included = i;
                break;
            }
            budget += bytes;
        }
        let has_more = has_more_by_count || included < page.len();
        let page = &page[..included];

        let targets = if let (Some(first), Some(last)) = (page.first(), page.last()) {
            sqlx::query!(
                r#"SELECT seq AS "seq!: i64", object_id AS "object_id!: CanvasObjectId"
                   FROM canvas_op_targets
                   WHERE channel_id = ? AND seq >= ? AND seq <= ?
                   ORDER BY seq"#,
                channel_id,
                first.seq,
                last.seq
            )
            .fetch_all(&mut *tx)
            .await?
        } else {
            Vec::new()
        };
        tx.commit().await?;

        let mut targets_by_seq: HashMap<i64, Vec<CanvasObjectId>> = HashMap::new();
        for row in targets {
            targets_by_seq
                .entry(row.seq)
                .or_default()
                .push(row.object_id);
        }

        let ops = page
            .iter()
            .map(|row| {
                let body = match row.kind.as_str() {
                    "place" => CanvasOpBody::Place(row.obj_id.map(|id| CanvasObject {
                        id,
                        kind: row.obj_kind.clone().unwrap_or_default(),
                        z_index: row.obj_z_index.unwrap_or(0),
                        x: row.obj_x.unwrap_or(0.0),
                        y: row.obj_y.unwrap_or(0.0),
                        w: row.obj_w.unwrap_or(0.0),
                        h: row.obj_h.unwrap_or(0.0),
                        props: row.obj_props.clone().unwrap_or_default(),
                        author_id: row.obj_author_id,
                        seq: row.obj_seq.unwrap_or(Seq(0)),
                        created_at: row.obj_created_at.unwrap_or(0),
                    })),
                    "remove" => CanvasOpBody::Remove(
                        targets_by_seq.get(&row.seq).cloned().unwrap_or_default(),
                    ),
                    "clear" => CanvasOpBody::Clear {
                        before_seq: row.bound_seq.context("canvas_op_bound guarantees this")?,
                        scope: ClearScope {
                            kinds: row
                                .clear_kinds
                                .as_deref()
                                .map(serde_json::from_str)
                                .transpose()
                                .context("clear_kinds is written as a JSON array")?
                                .unwrap_or_default(),
                            author_id: row.clear_author_id,
                        },
                    },
                    "restore" => CanvasOpBody::Restore {
                        target_op: row.target_op.context("canvas_op_target guarantees this")?,
                        object_ids: targets_by_seq.get(&row.seq).cloned().unwrap_or_default(),
                    },
                    "move" => {
                        let object_id = targets_by_seq
                            .get(&row.seq)
                            .and_then(|ids| ids.first())
                            .copied()
                            .context("a move op always writes its own target row")?;
                        CanvasOpBody::Move {
                            object_id,
                            x: row
                                .move_x
                                .context("canvas_op_move_bounds guarantees this")?,
                            y: row
                                .move_y
                                .context("canvas_op_move_bounds guarantees this")?,
                            w: row
                                .move_w
                                .context("canvas_op_move_bounds guarantees this")?,
                            h: row
                                .move_h
                                .context("canvas_op_move_bounds guarantees this")?,
                        }
                    }
                    "reorder" => {
                        let object_id = targets_by_seq
                            .get(&row.seq)
                            .and_then(|ids| ids.first())
                            .copied()
                            .context("a reorder op always writes its own target row")?;
                        CanvasOpBody::Reorder {
                            object_id,
                            z_index: row
                                .reorder_z
                                .context("canvas_op_reorder_z guarantees this")?,
                        }
                    }
                    "edit" => {
                        let object_id = targets_by_seq
                            .get(&row.seq)
                            .and_then(|ids| ids.first())
                            .copied()
                            .context("an edit op always writes its own target row")?;
                        CanvasOpBody::Edit {
                            object_id,
                            props: row
                                .edit_props
                                .clone()
                                .context("canvas_op_edit_props guarantees this")?,
                        }
                    }
                    other => anyhow::bail!("canvas_op_kind admits only 7 kinds, got {other}"),
                };
                Ok(CanvasOpEntry {
                    seq: row.seq,
                    id: row.id,
                    actor_id: row.actor_id,
                    created_at: row.created_at,
                    body,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        Ok(CanvasOpsPage {
            ops,
            latest_seq,
            has_more,
            reset: false,
        })
    }
}
