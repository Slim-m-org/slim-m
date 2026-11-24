// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store half of canvas edges (decision 0137): resolving the objects an edge is attached to,
//! the hull the server keeps for it, and what an erase, a clear, a move and a restore do to the
//! edges attached to the objects they touch.
//!
//! An erase or a clear takes every edge attached to what it removes, in the same transaction,
//! without naming those edges in the op's own ids: a remove frame stays within its 64 id bound
//! and an old client never hears of an object it never held. `canvas_op_cascades` records them so
//! an undo can bring them back, never inferred from `deleted_at`.

use std::collections::{HashMap, HashSet};

use serde_json::Value;
use sqlx::QueryBuilder;

use crate::canvas_edge::{
    EdgeEnd, HullPart, MAX_EDGES_PER_OBJECT, attached_ids, edge_ends, edge_hull,
};
use crate::ids::{CanvasObjectId, ChannelId};

/// How many ids one `IN (...)` list names at a time.
const BATCH: usize = 500;

/// The kinds an edge end may attach to; strokes, edges and media tiles cannot be.
pub(in crate::store) const ATTACHABLE_KINDS: [&str; 6] =
    ["note", "text", "shape", "image", "emoji", "module"];

/// Why an edge's ends were refused.
#[derive(Debug)]
pub(in crate::store) enum EdgeError {
    /// An end names an object that is not live in this channel.
    EndMissing,
    /// An end names an object of a kind an edge cannot attach to.
    EndNotAttachable,
    /// An end names an object that already carries the most edges it may.
    TooManyEdges,
    Db(sqlx::Error),
}

impl From<sqlx::Error> for EdgeError {
    fn from(err: sqlx::Error) -> Self {
        EdgeError::Db(err)
    }
}

/// An edge's attached ends and the hull derived from them, ready to write.
pub(in crate::store) struct ResolvedEdge {
    ends: Vec<(&'static str, CanvasObjectId)>,
    pub(in crate::store) hull: (f64, f64, f64, f64),
}

fn in_list(builder: &mut QueryBuilder<sqlx::Sqlite>, ids: &[CanvasObjectId]) {
    builder.push(" IN (");
    let mut separated = builder.separated(", ");
    for id in ids {
        separated.push_bind(*id);
    }
    builder.push(")");
}

async fn box_of(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    id: CanvasObjectId,
) -> Result<Option<HullPart>, sqlx::Error> {
    let row = sqlx::query!(
        r#"SELECT x AS "x!: f64", y AS "y!: f64", w AS "w!: f64", h AS "h!: f64"
           FROM canvas_objects WHERE id = ?"#,
        id
    )
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.map(|r| HullPart::Box {
        x: r.x,
        y: r.y,
        w: r.w,
        h: r.h,
    }))
}

/// The hull of an edge's props from the current boxes of its ends, or `None` when an end is gone.
pub(in crate::store) async fn hull_of(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    props: &Value,
) -> Result<Option<(f64, f64, f64, f64)>, sqlx::Error> {
    let Ok((from, to)) = edge_ends(props) else {
        return Ok(None);
    };
    let mut parts = Vec::with_capacity(2);
    for end in [from, to] {
        match end {
            EdgeEnd::Free { x, y } => parts.push(HullPart::Point { x, y }),
            EdgeEnd::Attached(id) => match box_of(tx, id).await? {
                Some(part) => parts.push(part),
                None => return Ok(None),
            },
        }
    }
    Ok(Some(edge_hull(&parts)))
}

/// Checks every attached end of an edge about to be placed or edited and derives its hull.
/// `edge_id` is the edge being edited, so its own current ends do not count against the cap.
pub(in crate::store) async fn resolve_edge(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    edge_id: CanvasObjectId,
    props: &Value,
) -> Result<ResolvedEdge, EdgeError> {
    let (from, to) = edge_ends(props).map_err(|_| EdgeError::EndMissing)?;
    let mut ends = Vec::with_capacity(2);
    let mut parts = Vec::with_capacity(2);
    for (name, end) in [("from", from), ("to", to)] {
        match end {
            EdgeEnd::Free { x, y } => parts.push(HullPart::Point { x, y }),
            EdgeEnd::Attached(id) => {
                let found = sqlx::query!(
                    r#"SELECT kind AS "kind!", x AS "x!: f64", y AS "y!: f64",
                              w AS "w!: f64", h AS "h!: f64"
                       FROM canvas_objects
                       WHERE id = ? AND channel_id = ? AND deleted_at IS NULL"#,
                    id,
                    channel_id
                )
                .fetch_optional(&mut **tx)
                .await?
                .ok_or(EdgeError::EndMissing)?;
                if !ATTACHABLE_KINDS.contains(&found.kind.as_str()) {
                    return Err(EdgeError::EndNotAttachable);
                }
                if live_edges_on(tx, id, edge_id).await? >= MAX_EDGES_PER_OBJECT {
                    return Err(EdgeError::TooManyEdges);
                }
                ends.push((name, id));
                parts.push(HullPart::Box {
                    x: found.x,
                    y: found.y,
                    w: found.w,
                    h: found.h,
                });
            }
        }
    }
    Ok(ResolvedEdge {
        ends,
        hull: edge_hull(&parts),
    })
}

async fn live_edges_on(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    object_id: CanvasObjectId,
    except: CanvasObjectId,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!: i64" FROM canvas_edge_ends e
           JOIN canvas_objects o ON o.id = e.edge_id
           WHERE e.object_id = ? AND e.edge_id != ? AND o.deleted_at IS NULL"#,
        object_id,
        except
    )
    .fetch_one(&mut **tx)
    .await
}

/// Writes the end rows of `edge_id`, replacing what it had.
pub(in crate::store) async fn write_ends(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    edge_id: CanvasObjectId,
    resolved: &ResolvedEdge,
) -> Result<(), sqlx::Error> {
    sqlx::query!("DELETE FROM canvas_edge_ends WHERE edge_id = ?", edge_id)
        .execute(&mut **tx)
        .await?;
    for (endpoint, object_id) in &resolved.ends {
        sqlx::query!(
            "INSERT INTO canvas_edge_ends (edge_id, endpoint, object_id) VALUES (?, ?, ?)",
            edge_id,
            endpoint,
            object_id
        )
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

/// Sets an edge's stored hull. Names all four columns so the R-Tree trigger fires, and skips the
/// extent ceiling `move_canvas_object_query` applies: an edge may span far more than one object.
pub(in crate::store) async fn set_hull(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    edge_id: CanvasObjectId,
    hull: (f64, f64, f64, f64),
) -> Result<(), sqlx::Error> {
    let (x, y, w, h) = hull;
    sqlx::query!(
        "UPDATE canvas_objects SET x = ?, y = ?, w = ?, h = ? WHERE id = ?",
        x,
        y,
        w,
        h,
        edge_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Recomputes the hull of every live edge attached to one of `moved`, after their boxes changed.
pub(in crate::store) async fn refresh_hulls(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    moved: &[CanvasObjectId],
) -> Result<(), sqlx::Error> {
    for chunk in moved.chunks(BATCH) {
        let mut builder = QueryBuilder::new(
            "SELECT DISTINCT e.edge_id, p.props FROM canvas_edge_ends e
             JOIN canvas_objects o ON o.id = e.edge_id AND o.deleted_at IS NULL
             JOIN canvas_object_props p ON p.object_id = e.edge_id
             WHERE e.object_id",
        );
        in_list(&mut builder, chunk);
        let rows = builder.build().fetch_all(&mut **tx).await?;
        for row in rows {
            use sqlx::Row;
            let edge_id: CanvasObjectId = row.try_get("edge_id")?;
            let props: String = row.try_get("props")?;
            let Ok(props) = serde_json::from_str::<Value>(&props) else {
                continue;
            };
            if let Some(hull) = hull_of(tx, &props).await? {
                set_hull(tx, edge_id, hull).await?;
            }
        }
    }
    Ok(())
}

/// Soft-deletes every live edge attached to one of `erased`, locked or not: no dangling end
/// outranks a lock. Returns the edges taken.
pub(in crate::store) async fn cascade_erase(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    erased: &[CanvasObjectId],
    now: i64,
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    let mut taken = Vec::new();
    for chunk in erased.chunks(BATCH) {
        let mut builder = QueryBuilder::new("UPDATE canvas_objects SET deleted_at = ");
        builder.push_bind(now);
        builder.push(" WHERE channel_id = ");
        builder.push_bind(channel_id);
        builder.push(
            " AND kind = 'edge' AND deleted_at IS NULL
              AND id IN (SELECT edge_id FROM canvas_edge_ends WHERE object_id",
        );
        in_list(&mut builder, chunk);
        builder.push(") RETURNING id");
        let rows: Vec<CanvasObjectId> = builder.build_query_scalar().fetch_all(&mut **tx).await?;
        taken.extend(rows);
    }
    Ok(taken)
}

/// After a clear's sweep: soft-deletes every live edge left with an erased end.
pub(in crate::store) async fn cascade_after_clear(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    now: i64,
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    sqlx::query_scalar!(
        r#"UPDATE canvas_objects SET deleted_at = ?
           WHERE channel_id = ? AND kind = 'edge' AND deleted_at IS NULL
             AND id IN (SELECT e.edge_id FROM canvas_edge_ends e
                        JOIN canvas_objects end_o ON end_o.id = e.object_id
                        WHERE end_o.channel_id = ? AND end_o.deleted_at IS NOT NULL)
           RETURNING id AS "id!: CanvasObjectId""#,
        now,
        channel_id,
        channel_id
    )
    .fetch_all(&mut **tx)
    .await
}

/// Records the edges an op took with it, once the op has its seq.
pub(in crate::store) async fn record_cascades(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    seq: i64,
    cascaded: &[CanvasObjectId],
) -> Result<(), sqlx::Error> {
    for chunk in cascaded.chunks(BATCH) {
        let mut builder =
            QueryBuilder::new("INSERT INTO canvas_op_cascades (channel_id, seq, object_id) ");
        builder.push_values(chunk, |mut row, id| {
            row.push_bind(channel_id).push_bind(seq).push_bind(*id);
        });
        builder.build().execute(&mut **tx).await?;
    }
    Ok(())
}

/// The edges an op took with it.
pub(in crate::store) async fn cascades_of(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    seq: i64,
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT object_id AS "object_id!: CanvasObjectId" FROM canvas_op_cascades
           WHERE channel_id = ? AND seq = ?"#,
        channel_id,
        seq
    )
    .fetch_all(&mut **tx)
    .await
}

/// Of the edges erased at `deleted_at` that are among `reviving`, the ones whose attached ends
/// are not all live once `reviving` is back; the ends come from props, never from row counts.
pub(in crate::store) async fn edges_to_skip(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    deleted_at: i64,
    reviving: &HashSet<CanvasObjectId>,
) -> Result<HashSet<CanvasObjectId>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT o.id AS "id!: CanvasObjectId", p.props AS "props!"
           FROM canvas_objects o JOIN canvas_object_props p ON p.object_id = o.id
           WHERE o.channel_id = ? AND o.kind = 'edge' AND o.deleted_at = ?"#,
        channel_id,
        deleted_at
    )
    .fetch_all(&mut **tx)
    .await?;
    let mut attached: HashMap<CanvasObjectId, Vec<CanvasObjectId>> = HashMap::new();
    for row in rows.into_iter().filter(|r| reviving.contains(&r.id)) {
        let ids = serde_json::from_str::<Value>(&row.props)
            .map(|props| attached_ids(&props))
            .unwrap_or_default();
        attached.insert(row.id, ids);
    }
    let to_check: Vec<CanvasObjectId> = attached
        .values()
        .flatten()
        .copied()
        .filter(|id| !reviving.contains(id))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let live = live_among(tx, &to_check).await?;
    Ok(attached
        .into_iter()
        .filter(|(_, ids)| {
            !ids.iter()
                .all(|id| reviving.contains(id) || live.contains(id))
        })
        .map(|(edge, _)| edge)
        .collect())
}

async fn live_among(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    ids: &[CanvasObjectId],
) -> Result<HashSet<CanvasObjectId>, sqlx::Error> {
    let mut live = HashSet::new();
    for chunk in ids.chunks(BATCH) {
        let mut builder =
            QueryBuilder::new("SELECT id FROM canvas_objects WHERE deleted_at IS NULL AND id");
        in_list(&mut builder, chunk);
        let rows: Vec<CanvasObjectId> = builder.build_query_scalar().fetch_all(&mut **tx).await?;
        live.extend(rows);
    }
    Ok(live)
}

/// Dead edges attached to any of `ids`, so a purge takes them with the object they hung on.
pub(in crate::store) async fn dead_edges_on(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    ids: &[CanvasObjectId],
) -> Result<Vec<CanvasObjectId>, sqlx::Error> {
    let mut found = Vec::new();
    for chunk in ids.chunks(BATCH) {
        let mut builder = QueryBuilder::new(
            "SELECT DISTINCT e.edge_id FROM canvas_edge_ends e
             JOIN canvas_objects o ON o.id = e.edge_id
             WHERE o.deleted_at IS NOT NULL AND e.object_id",
        );
        in_list(&mut builder, chunk);
        let rows: Vec<CanvasObjectId> = builder.build_query_scalar().fetch_all(&mut **tx).await?;
        found.extend(rows);
    }
    Ok(found)
}
