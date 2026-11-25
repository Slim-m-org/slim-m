// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The copy half of a canvas export (decision 0139, 4.5): which objects are copied, the new ids, and the rows written for them.
//!
//! Everything runs in the caller's write transaction. Rows go in bounded multi-row inserts, the
//! old-to-new id map lives in a temp table so the side tables copy in one statement each.

use std::collections::{HashMap, HashSet};

use serde_json::Value;
use sqlx::QueryBuilder;

use super::canvas_edges::{resolve_edge, set_hull, write_ends};
use super::canvas_tile_scenes::{MODULE_TILE_KIND, ModuleTileRef};
use super::channel_key;
use crate::canvas_edge::attached_ids;
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};

/// Objects read and written per statement.
const CHUNK: usize = 500;

const EDGE_KIND: &str = "edge";

/// What will be copied and what will not.
pub(super) struct ExportPlan {
    /// Source ids to copy, bottom of the stacking order first.
    pub(super) order: Vec<CanvasObjectId>,
    pub(super) map: HashMap<CanvasObjectId, CanvasObjectId>,
    /// Objects left behind: module tiles whose module is gone, and edges that lost an end.
    pub(super) dropped: Vec<CanvasObjectId>,
}

/// An edge copied but not yet attached: its ends are resolved once every object exists.
pub(super) struct CopiedEdge {
    pub(super) id: CanvasObjectId,
    pub(super) props: Value,
}

#[derive(sqlx::FromRow)]
struct SourceRow {
    id: CanvasObjectId,
    kind: String,
    z_index: i64,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    author_id: Option<UserId>,
    created_at: i64,
    props: String,
}

/// Mints the id map for every live object of `source` and drops what cannot be copied.
pub(super) async fn plan_copy(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    source: ChannelId,
) -> Result<ExportPlan, sqlx::Error> {
    let live: Vec<(CanvasObjectId, String)> = sqlx::query_as(
        "SELECT id, kind FROM canvas_objects \
         WHERE channel_id = ? AND deleted_at IS NULL ORDER BY z_index, seq",
    )
    .bind(source)
    .fetch_all(&mut **tx)
    .await?;
    let installed: HashSet<String> =
        sqlx::query_scalar("SELECT id FROM installed_modules WHERE enabled = 1")
            .fetch_all(&mut **tx)
            .await?
            .into_iter()
            .collect();
    let mut dropped: HashSet<CanvasObjectId> = HashSet::new();
    for (id, props) in props_of_kind(tx, source, MODULE_TILE_KIND).await? {
        let live_module = ModuleTileRef::from_props(&props)
            .is_some_and(|tile| installed.contains(&tile.module_id));
        if !live_module {
            dropped.insert(id);
        }
    }
    let present: HashSet<CanvasObjectId> = live
        .iter()
        .map(|(id, _)| *id)
        .filter(|id| !dropped.contains(id))
        .collect();
    for (id, props) in props_of_kind(tx, source, EDGE_KIND).await? {
        if attached_ids(&props)
            .iter()
            .any(|end| !present.contains(end))
        {
            dropped.insert(id);
        }
    }
    let order: Vec<CanvasObjectId> = live
        .into_iter()
        .map(|(id, _)| id)
        .filter(|id| !dropped.contains(id))
        .collect();
    let map = order
        .iter()
        .map(|id| (*id, CanvasObjectId::generate()))
        .collect();
    Ok(ExportPlan {
        order,
        map,
        dropped: dropped.into_iter().collect(),
    })
}

async fn props_of_kind(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    source: ChannelId,
    kind: &str,
) -> Result<Vec<(CanvasObjectId, Value)>, sqlx::Error> {
    let rows: Vec<(CanvasObjectId, String)> = sqlx::query_as(
        "SELECT o.id, p.props FROM canvas_objects o \
         JOIN canvas_object_props p ON p.object_id = o.id \
         WHERE o.channel_id = ? AND o.deleted_at IS NULL AND o.kind = ?",
    )
    .bind(source)
    .bind(kind)
    .fetch_all(&mut **tx)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, props)| (id, serde_json::from_str(&props).unwrap_or(Value::Null)))
        .collect())
}

/// Copies every planned object into `target` with seqs dense from `first_seq`, and returns the edges still to attach.
pub(super) async fn copy_objects(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    target: ChannelId,
    plan: &ExportPlan,
    now: i64,
) -> Result<Vec<CopiedEdge>, sqlx::Error> {
    sqlx::query("CREATE TEMP TABLE canvas_export_map (old_id BLOB PRIMARY KEY, new_id BLOB NOT NULL) WITHOUT ROWID")
        .execute(&mut **tx)
        .await?;
    let count = plan.order.len() as i64;
    let first_seq: i64 = sqlx::query_scalar(
        "UPDATE channel_seq_counters SET next_seq = next_seq + ? \
         WHERE channel_id = ? AND stream = 'canvas' RETURNING next_seq - ?",
    )
    .bind(count)
    .bind(target)
    .bind(count)
    .fetch_one(&mut **tx)
    .await?;
    let mut edges = Vec::new();
    let mut seq = first_seq;
    for chunk in plan.order.chunks(CHUNK) {
        let mut rows = fetch_rows(tx, chunk).await?;
        let batch: Vec<(SourceRow, CanvasObjectId, i64)> = chunk
            .iter()
            .filter_map(|old| rows.remove(old))
            .map(|row| {
                let new_id = plan.map[&row.id];
                seq += 1;
                (row, new_id, seq - 1)
            })
            .collect();
        insert_chunk(tx, target, now, &batch, plan, &mut edges).await?;
    }
    Ok(edges)
}

async fn fetch_rows(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    ids: &[CanvasObjectId],
) -> Result<HashMap<CanvasObjectId, SourceRow>, sqlx::Error> {
    let mut query = QueryBuilder::new(
        "SELECT o.id, o.kind, o.z_index, o.x, o.y, o.w, o.h, o.author_id, o.created_at, p.props \
         FROM canvas_objects o JOIN canvas_object_props p ON p.object_id = o.id WHERE o.id IN (",
    );
    let mut separated = query.separated(", ");
    for id in ids {
        separated.push_bind(*id);
    }
    query.push(")");
    let rows: Vec<SourceRow> = query.build_query_as().fetch_all(&mut **tx).await?;
    Ok(rows.into_iter().map(|row| (row.id, row)).collect())
}

async fn insert_chunk(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    target: ChannelId,
    now: i64,
    batch: &[(SourceRow, CanvasObjectId, i64)],
    plan: &ExportPlan,
    edges: &mut Vec<CopiedEdge>,
) -> Result<(), sqlx::Error> {
    if batch.is_empty() {
        return Ok(());
    }
    let key = channel_key(target);
    let props: Vec<String> = batch
        .iter()
        .map(|(row, new_id, _)| rewritten_props(row, *new_id, plan, edges))
        .collect();
    let mut objects = QueryBuilder::new(
        "INSERT INTO canvas_objects \
         (id, channel_id, channel_key, kind, z_index, x, y, w, h, author_id, seq, created_at) ",
    );
    objects.push_values(batch, |mut b, (row, new_id, seq)| {
        b.push_bind(*new_id)
            .push_bind(target)
            .push_bind(key)
            .push_bind(row.kind.as_str())
            .push_bind(row.z_index)
            .push_bind(row.x)
            .push_bind(row.y)
            .push_bind(row.w)
            .push_bind(row.h)
            .push_bind(row.author_id)
            .push_bind(*seq)
            .push_bind(row.created_at);
    });
    objects.build().execute(&mut **tx).await?;
    let mut stored = QueryBuilder::new("INSERT INTO canvas_object_props (object_id, props) ");
    stored.push_values(
        batch.iter().zip(&props),
        |mut b, ((_, new_id, _), props)| {
            b.push_bind(*new_id).push_bind(props.as_str());
        },
    );
    stored.build().execute(&mut **tx).await?;
    let mut ops = QueryBuilder::new(
        "INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at) ",
    );
    ops.push_values(batch, |mut b, (row, _, seq)| {
        b.push_bind(target)
            .push_bind(*seq)
            .push_bind(CanvasOpId::generate())
            .push("'place'")
            .push_bind(row.author_id)
            .push_bind(now);
    });
    ops.build().execute(&mut **tx).await?;
    let mut targets =
        QueryBuilder::new("INSERT INTO canvas_op_targets (channel_id, seq, object_id) ");
    targets.push_values(batch, |mut b, (_, new_id, seq)| {
        b.push_bind(target).push_bind(*seq).push_bind(*new_id);
    });
    targets.build().execute(&mut **tx).await?;
    let mut map = QueryBuilder::new("INSERT INTO canvas_export_map (old_id, new_id) ");
    map.push_values(batch, |mut b, (row, new_id, _)| {
        b.push_bind(row.id).push_bind(*new_id);
    });
    map.build().execute(&mut **tx).await?;
    Ok(())
}

/// The props to store for the copy; an edge's attached ends point at the copies and it is queued to attach.
fn rewritten_props(
    row: &SourceRow,
    new_id: CanvasObjectId,
    plan: &ExportPlan,
    edges: &mut Vec<CopiedEdge>,
) -> String {
    if row.kind != EDGE_KIND {
        return row.props.clone();
    }
    let mut props: Value = serde_json::from_str(&row.props).unwrap_or(Value::Null);
    for end in ["from", "to"] {
        let Some(slot) = props.get_mut(end).and_then(|end| end.get_mut("object_id")) else {
            continue;
        };
        let copy = slot
            .as_str()
            .and_then(|raw| uuid::Uuid::parse_str(raw).ok())
            .and_then(|raw| plan.map.get(&CanvasObjectId(raw)));
        if let Some(copy) = copy {
            *slot = Value::String(copy.to_string());
        }
    }
    let stored = props.to_string();
    edges.push(CopiedEdge { id: new_id, props });
    stored
}

/// Attaches every copied edge by the code a placement uses, and recomputes its hull.
pub(super) async fn attach_edges(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    target: ChannelId,
    edges: &[CopiedEdge],
) -> anyhow::Result<()> {
    for edge in edges {
        let resolved = resolve_edge(tx, target, edge.id, &edge.props)
            .await
            .map_err(|err| anyhow::anyhow!("an exported edge could not be attached: {err:?}"))?;
        write_ends(tx, edge.id, &resolved).await?;
        set_hull(tx, edge.id, resolved.hull).await?;
    }
    Ok(())
}

/// Copies the rows that hang off an object, then drops the id map.
///
/// Timers on a copied tile scene are nulled: the copy refreshes only when someone presses it.
pub(super) async fn copy_side_rows(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    target: ChannelId,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO canvas_object_attachments (object_id, sha256) \
         SELECT m.new_id, a.sha256 FROM canvas_object_attachments a \
         JOIN canvas_export_map m ON m.old_id = a.object_id",
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "INSERT INTO blocked_author_canvas_objects (object_id, author_id) \
         SELECT m.new_id, b.author_id FROM blocked_author_canvas_objects b \
         JOIN canvas_export_map m ON m.old_id = b.object_id \
         JOIN canvas_objects n ON n.id = m.new_id WHERE n.author_id IS NULL",
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "INSERT INTO canvas_object_locks (object_id, channel_id, locked_by, locked_at) \
         SELECT m.new_id, ?, l.locked_by, l.locked_at FROM canvas_object_locks l \
         JOIN canvas_export_map m ON m.old_id = l.object_id",
    )
    .bind(target)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "INSERT INTO canvas_tile_scenes \
         (object_id, channel_id, output, ran_by, ran_at, refresh_due_at, refresh_until_at) \
         SELECT m.new_id, ?, s.output, s.ran_by, s.ran_at, NULL, NULL FROM canvas_tile_scenes s \
         JOIN canvas_export_map m ON m.old_id = s.object_id",
    )
    .bind(target)
    .execute(&mut **tx)
    .await?;
    sqlx::query("DROP TABLE canvas_export_map")
        .execute(&mut **tx)
        .await?;
    Ok(())
}
