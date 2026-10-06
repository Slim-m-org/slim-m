// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas object persistence and the viewport read path over the R-Tree that
//! migration 0015 keeps in sync by trigger.
//!
//! Two things about this read path are worth knowing before changing it.
//!
//! R-Tree coordinates are 32-bit floats, and SQLite rounds a bounding box
//! outwards when it stores one, so the index over-reports near its precision
//! limit and never under-reports. Every query therefore repeats the
//! intersection test in exact `REAL` arithmetic against `canvas_objects`, and
//! the R-Tree is only ever a way to avoid looking at most rows.
//!
//! The delta is geometric, not a diff against server-held state. A client
//! sends the rectangle it is entering and the one it is leaving, and gets
//! back what is in the first and not the second, plus anything inside both
//! that is newer than its cursor. Nothing per-connection is stored, so a
//! reconnect costs one ordinary request and a pan is idempotent.
//!
//! `CROSS JOIN` in the viewport read is load-bearing, not style. It pins the
//! R-Tree as the outer loop. Left as a plain join, SQLite on a database that
//! has never been ANALYZEd drives from `canvas_objects` instead and probes the
//! R-Tree by rowid, which reads every object in the channel and prunes
//! nothing; `tests/canvas.rs` asserts the plan rather than trusting it.

use anyhow::Context;
use sqlx::SqliteExecutor;

use super::canvas_ops::insert_place_op;
use super::{Store, now_ms};
use crate::ids::{CanvasObjectId, ChannelId, Seq, UserId};

// Geometry lives in `canvas_geometry`; re-exported so every existing path holds.
pub use super::canvas_geometry::{
    MAX_CANVAS_OBJECT_CAP, MAX_OBJECT_EXTENT, MAX_OBJECTS_PER_CHANNEL, MIN_CANVAS_OBJECT_CAP,
    WORLD_LIMIT,
};
pub(crate) use super::canvas_geometry::{channel_key, valid_bounds};

/// A placed canvas object.
#[derive(Debug, Clone)]
pub struct CanvasObject {
    pub id: CanvasObjectId,
    pub kind: String,
    pub z_index: i64,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// Kind-specific fields as a JSON object, opaque to the server.
    pub props: String,
    pub author_id: Option<UserId>,
    pub seq: Seq,
    pub created_at: i64,
}

/// An axis-aligned rectangle in world coordinates.
#[derive(Debug, Clone, Copy)]
pub struct Rect {
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
}

/// One viewport read. `previous` is the rectangle the client is leaving, and
/// its absence means a cold fetch of `view` with nothing held back.
#[derive(Debug, Clone)]
pub struct ViewportQuery {
    pub view: Rect,
    pub previous: Option<Rect>,
    pub after_seq: i64,
    pub limit: i64,
}

/// The outcome of a placement: the stored row, and whether this call is what
/// wrote it.
///
/// `fresh` is what the write handler gates its fan-out on. Without it an
/// idempotent replay - a retry after a lost response, which the client's
/// commit queue will produce under a 429 - would publish a second frame for an
/// object every viewer already holds.
#[derive(Debug)]
pub struct Placement {
    pub object: CanvasObject,
    pub fresh: bool,
}

/// Why placing an object failed.
#[derive(Debug)]
pub enum PlaceError {
    /// This id already belongs to an object in another channel.
    IdConflict,
    /// This id belongs to an object in this same channel that has since been
    /// removed, distinct from [`PlaceError::IdConflict`] so a retry racing an
    /// erase gets an honest answer rather than "id taken".
    Removed,
    /// The object's bounds are not finite, have negative extent, exceed
    /// [`MAX_OBJECT_EXTENT`], or fall outside the bounded world.
    OutOfBounds,
    /// This channel's canvas already holds [`MAX_OBJECTS_PER_CHANNEL`].
    ChannelFull,
    /// An `image` object named an attachment that was never uploaded, was
    /// already swept as an orphan, or that this caller may not reference -
    /// one answer for all three, the same collapse `SendError::AttachmentNotFound`
    /// already makes for a message attachment.
    AttachmentNotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for PlaceError {
    fn from(err: sqlx::Error) -> Self {
        PlaceError::Internal(err.into())
    }
}

impl From<anyhow::Error> for PlaceError {
    fn from(err: anyhow::Error) -> Self {
        PlaceError::Internal(err)
    }
}

impl From<super::attachments::LinkError> for PlaceError {
    fn from(err: super::attachments::LinkError) -> Self {
        match err {
            super::attachments::LinkError::NotFound => PlaceError::AttachmentNotFound,
            super::attachments::LinkError::Internal(e) => PlaceError::Internal(e),
        }
    }
}

/// What [`Store::place_canvas_object`] needs beyond the caller and the
/// object's identity, grouped so the function stays under the 7-parameter
/// ceiling rather than growing a longer flat signature.
pub struct PlaceRequest<'a> {
    pub kind: &'a str,
    pub bounds: (f64, f64, f64, f64),
    pub props: &'a str,
    /// The sha256 an `image` object's `props.attachment` names, resolved by
    /// the caller before this runs. `None` for every other kind.
    pub attachment: Option<&'a [u8]>,
}

impl Store {
    /// Places an object on a channel's canvas, idempotent by `id` and taking
    /// the next value from that channel's `canvas` sequence stream, which is
    /// independent of its message stream.
    ///
    /// `request.attachment`, when present, is checked with the same
    /// `may_link` this caller's own uploads or already-visible bytes already
    /// pass for a message, before the write lock is taken, for the reason
    /// `Store::send_message`'s own note on `may_link` gives.
    pub async fn place_canvas_object(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
        id: CanvasObjectId,
        request: PlaceRequest<'_>,
    ) -> Result<Placement, PlaceError> {
        let PlaceRequest {
            kind,
            bounds,
            props,
            attachment,
        } = request;
        let (x, y, w, h) = bounds;
        if !valid_bounds(x, y, w, h) {
            return Err(PlaceError::OutOfBounds);
        }
        if let Some(sha256) = attachment
            && !super::attachments::may_link(self, author_id, sha256).await?
        {
            return Err(PlaceError::AttachmentNotFound);
        }

        // Reads the id before deciding to write, so the write lock is taken up
        // front (see `Store::begin_write`).
        let mut tx = self.begin_write().await?;
        if let Some(existing) = fetch_object(&mut tx, id).await? {
            tx.commit().await?;
            return match (existing.0 == channel_id, existing.1) {
                (true, false) => Ok(Placement {
                    object: existing.2,
                    fresh: false,
                }),
                (true, true) => Err(PlaceError::Removed),
                // A removed row keeps the id, so falling through would be a UNIQUE violation reported as a 500.
                (false, _) => Err(PlaceError::IdConflict),
            };
        }

        let live = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "count!: i64" FROM canvas_objects
               WHERE channel_id = ? AND deleted_at IS NULL"#,
            channel_id
        )
        .fetch_one(&mut *tx)
        .await?;
        // Read in this same write transaction as the count above it.
        let cap = super::space::read_canvas_object_cap(&mut *tx).await?;
        if live >= cap {
            tx.commit().await?;
            return Err(PlaceError::ChannelFull);
        }

        let seq = next_canvas_seq(&mut tx, channel_id).await?;

        let key = channel_key(channel_id);
        let now = now_ms();
        // `z_index` is seeded from `seq`, so the default paint order is the
        // order things were drawn in and raising an object is a later edit.
        sqlx::query!(
            r#"INSERT INTO canvas_objects
                   (id, channel_id, channel_key, kind, z_index, x, y, w, h, props,
                    author_id, seq, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
            id,
            channel_id,
            key,
            kind,
            seq,
            x,
            y,
            w,
            h,
            props,
            author_id,
            seq,
            now
        )
        .execute(&mut *tx)
        .await?;
        if let Some(sha256) = attachment {
            sqlx::query!(
                "INSERT INTO canvas_object_attachments (object_id, sha256) VALUES (?, ?)",
                id,
                sha256
            )
            .execute(&mut *tx)
            .await?;
        }
        // Same transaction, same seq, or the op stream stops being dense.
        insert_place_op(&mut tx, channel_id, seq, author_id, id, now).await?;
        tx.commit().await?;

        Ok(Placement {
            object: CanvasObject {
                id,
                kind: kind.to_owned(),
                z_index: seq,
                x,
                y,
                w,
                h,
                props: props.to_owned(),
                author_id: Some(author_id),
                seq: Seq(seq),
                created_at: now,
            },
            fresh: true,
        })
    }

    /// The channel's live objects intersecting `view`, z-ordered, held back to
    /// what the caller does not already have when `previous` is given.
    ///
    /// The `LIMIT` is applied to the *newest* objects and the page is then
    /// reversed back into paint order, so a region holding more than the limit
    /// answers with the most recent ink rather than the oldest. Ordered
    /// ascending, the truncation went the other way: `z_index` is seeded from
    /// `seq`, so a busy region would have answered a reconnecting client with
    /// a fixed prefix of old strokes and never with what had just been drawn.
    ///
    /// The latest sequence and the objects are read from
    /// one deferred transaction so a write landing between the two cannot
    /// produce a `latest_seq` the page does not cover: over-reporting
    /// self-heals on the next read, under-reporting does not. The sequence is
    /// the cursor a client keeps for its next viewport read.
    pub async fn viewport_snapshot(
        &self,
        channel_id: ChannelId,
        query: &ViewportQuery,
    ) -> anyhow::Result<(i64, Vec<CanvasObject>)> {
        let mut tx = self.begin_read().await?;
        let latest_seq = latest_canvas_seq_query(&mut *tx, channel_id).await?;
        let objects = viewport_objects_query(&mut *tx, channel_id, query).await?;
        tx.commit().await?;
        Ok((latest_seq, objects))
    }
}

async fn viewport_objects_query<'e, E>(
    executor: E,
    channel_id: ChannelId,
    query: &ViewportQuery,
) -> anyhow::Result<Vec<CanvasObject>>
where
    E: SqliteExecutor<'e>,
{
    let key = channel_key(channel_id);
    let view = query.view;
    let previous = query.previous.unwrap_or(Rect {
        min_x: 0.0,
        min_y: 0.0,
        max_x: 0.0,
        max_y: 0.0,
    });
    let has_previous = i64::from(query.previous.is_some());

    let rows = sqlx::query_as!(
        CanvasObject,
        r#"SELECT o.id AS "id!: CanvasObjectId", o.kind AS "kind!",
                  o.z_index AS "z_index!: i64",
                  o.x AS "x!: f64", o.y AS "y!: f64",
                  o.w AS "w!: f64", o.h AS "h!: f64",
                  o.props AS "props!", o.author_id AS "author_id: UserId",
                  o.seq AS "seq!: Seq", o.created_at AS "created_at!: i64"
           FROM canvas_rtree r
           CROSS JOIN canvas_objects o ON o.rt_id = r.rt_id
           WHERE r.min_key <= ? AND r.max_key >= ?
             AND r.max_x >= ? AND r.min_x <= ?
             AND r.max_y >= ? AND r.min_y <= ?
             AND o.channel_id = ? AND o.deleted_at IS NULL
             AND o.x <= ? AND o.x + o.w >= ?
             AND o.y <= ? AND o.y + o.h >= ?
             AND (? = 0 OR o.seq > ?
                  OR NOT (o.x <= ? AND o.x + o.w >= ?
                          AND o.y <= ? AND o.y + o.h >= ?))
           ORDER BY o.z_index DESC, o.seq DESC
           LIMIT ?"#,
        key,
        key,
        view.min_x,
        view.max_x,
        view.min_y,
        view.max_y,
        channel_id,
        view.max_x,
        view.min_x,
        view.max_y,
        view.min_y,
        has_previous,
        query.after_seq,
        previous.max_x,
        previous.min_x,
        previous.max_y,
        previous.min_y,
        query.limit
    )
    .fetch_all(executor)
    .await?;
    Ok(rows.into_iter().rev().collect())
}

async fn latest_canvas_seq_query<'e, E>(executor: E, channel_id: ChannelId) -> anyhow::Result<i64>
where
    E: SqliteExecutor<'e>,
{
    let seq = sqlx::query_scalar!(
        r#"SELECT next_seq - 1 AS "seq!: i64" FROM channel_seq_counters
           WHERE channel_id = ? AND stream = 'canvas'"#,
        channel_id
    )
    .fetch_optional(executor)
    .await?;
    Ok(seq.unwrap_or(0))
}

/// Fetches one object, the channel it belongs to and whether it is removed,
/// for the idempotency check on placement.
///
/// Removed rows are included deliberately: `canvas_objects.id` is `UNIQUE`
/// over live and dead rows alike, so a lookup that filtered them out would let
/// a replay of a since-removed id fall through to the insert and surface the
/// constraint violation as a 500.
///
/// It looks the id up across the deployment rather than within the caller's
/// channel, which is the one unauthorized read in the write path: somebody
/// holding `USE_CANVAS` anywhere can learn whether an id exists somewhere.
/// Accepted rather than closed, because ids are UUIDv7 and the only ones a
/// caller can name are ones a viewport read already handed them.
async fn fetch_object(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    id: CanvasObjectId,
) -> anyhow::Result<Option<(ChannelId, bool, CanvasObject)>> {
    let row = sqlx::query!(
        r#"SELECT channel_id AS "channel_id!: ChannelId", id AS "id!: CanvasObjectId",
                  kind AS "kind!", z_index AS "z_index!: i64",
                  x AS "x!: f64", y AS "y!: f64", w AS "w!: f64", h AS "h!: f64",
                  props AS "props!", author_id AS "author_id: UserId",
                  seq AS "seq!: Seq", created_at AS "created_at!: i64",
                  deleted_at AS "deleted_at: i64"
           FROM canvas_objects WHERE id = ?"#,
        id
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.map(|r| {
        (
            r.channel_id,
            r.deleted_at.is_some(),
            CanvasObject {
                id: r.id,
                kind: r.kind,
                z_index: r.z_index,
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
                props: r.props,
                author_id: r.author_id,
                seq: r.seq,
                created_at: r.created_at,
            },
        )
    }))
}

/// Allocates the channel's next canvas stream seq inside the caller's write transaction.
pub(super) async fn next_canvas_seq(
    conn: &mut sqlx::SqliteConnection,
    channel_id: ChannelId,
) -> anyhow::Result<i64> {
    // RETURNING sees the updated row, so `next_seq - 1` is the seq just handed out.
    sqlx::query_scalar!(
        r#"UPDATE channel_seq_counters SET next_seq = next_seq + 1
           WHERE channel_id = ? AND stream = 'canvas'
           RETURNING next_seq - 1 AS "seq!: i64""#,
        channel_id
    )
    .fetch_optional(&mut *conn)
    .await?
    .context("channel has no canvas sequence counter")
}
