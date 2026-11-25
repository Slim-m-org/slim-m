// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting a board into a new canvas channel, copy and optional clear in one write transaction (decision 0139).

use super::canvas_batch::ensure_room;
use super::canvas_clear::{ClearInTx, clear_in_tx};
use super::canvas_export_copy::{attach_edges, copy_objects, copy_side_rows, plan_copy};
use super::canvas_ops_apply::current_canvas_seq;
use super::canvas_ops_write::{ClearScope, SubmitOpError, SubmittedOp};
use super::{PlaceError, Store, now_ms};
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelCategoryId, ChannelId, UserId};
use crate::store::channels::channel_create::{
    ChannelDefaults, CreateChannelError, NewChannel, fetch_channel_by_id, insert_channel_in_tx,
};
use crate::store::{CANVAS_CHANNEL_KIND, Channel, DM_CHANNEL_KIND};

/// The most live objects one export copies, so the writer lock is held for a bounded time.
///
/// Measured in release at 20,000 mixed objects: 0.46 s to copy and 0.67 s to copy and clear.
pub const MAX_EXPORT_OBJECTS: i64 = 20_000;

/// What to export and where it goes.
pub struct ExportRequest<'a> {
    /// The new channel; it keys the whole request, retries included.
    pub id: ChannelId,
    pub source_id: ChannelId,
    pub actor_id: UserId,
    pub name: &'a str,
    pub category_id: Option<ChannelCategoryId>,
    pub voice_enabled: bool,
    pub clear_source: bool,
}

/// What an export did, or what the first try of this `id` did.
pub struct CanvasExport {
    pub channel: Channel,
    /// False when this call replayed an earlier one: nothing was written and nothing is published.
    pub fresh: bool,
    pub copied: i64,
    pub skipped: i64,
    pub cleared: i64,
    pub spared: i64,
    /// Skipped objects that stayed on the source because they could not be copied; 0 without a clear.
    pub left: i64,
    /// The clear that emptied the source, when this call made one that removed anything.
    pub clear_op: Option<SubmittedOp>,
}

#[derive(Debug)]
pub enum ExportError {
    Channel(CreateChannelError),
    /// The source holds more live objects than [`MAX_EXPORT_OBJECTS`].
    TooLarge,
    /// The new channel's object cap refuses the count.
    Full,
    /// The source is gone, or its board closed since the caller was checked.
    SourceUnavailable,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ExportError {
    fn from(err: sqlx::Error) -> Self {
        ExportError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ExportError {
    fn from(err: anyhow::Error) -> Self {
        ExportError::Internal(err)
    }
}

impl From<CreateChannelError> for ExportError {
    fn from(err: CreateChannelError) -> Self {
        ExportError::Channel(err)
    }
}

impl From<PlaceError> for ExportError {
    fn from(err: PlaceError) -> Self {
        match err {
            PlaceError::ChannelFull => ExportError::Full,
            other => ExportError::Internal(anyhow::anyhow!("sizing an export failed: {other:?}")),
        }
    }
}

impl From<SubmitOpError> for ExportError {
    fn from(err: SubmitOpError) -> Self {
        ExportError::Internal(anyhow::anyhow!(
            "clearing an export's source failed: {err:?}"
        ))
    }
}

#[derive(sqlx::FromRow)]
struct ExportRow {
    source_channel_id: ChannelId,
    clear_source: bool,
    copied: i64,
    skipped: i64,
    cleared: i64,
    spared: i64,
}

#[derive(sqlx::FromRow)]
struct SourceRow {
    deleted: bool,
    synced: bool,
}

impl Store {
    /// The refusals that need no write lock: the ceiling, unless `id` already names an export (a replay owes the ceiling nothing).
    pub async fn check_canvas_export(
        &self,
        id: ChannelId,
        source_id: ChannelId,
    ) -> Result<(), ExportError> {
        let known: Option<i64> =
            sqlx::query_scalar("SELECT 1 FROM canvas_exports WHERE channel_id = ?")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?;
        if known.is_some() {
            return Ok(());
        }
        let live: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ? AND deleted_at IS NULL",
        )
        .bind(source_id)
        .fetch_one(&self.pool)
        .await?;
        match live > MAX_EXPORT_OBJECTS {
            true => Err(ExportError::TooLarge),
            false => Ok(()),
        }
    }

    /// Copies the source's live board into a new canvas channel `request.id`, clearing the source in the same transaction when asked.
    ///
    /// Idempotent by `id`: an id that already names this export (same source, same `clear_source`)
    /// answers the stored outcome; any other channel under that id is an `IdConflict`.
    pub async fn export_canvas_to_new_channel(
        &self,
        request: ExportRequest<'_>,
    ) -> Result<CanvasExport, ExportError> {
        let mut tx = self.begin_write().await?;
        if let Some(replay) = replay_of(&mut tx, &request).await? {
            tx.commit().await?;
            return Ok(replay);
        }
        let now = now_ms();
        let source = source_of(&mut tx, request.source_id).await?;
        let live: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM canvas_objects WHERE channel_id = ? AND deleted_at IS NULL",
        )
        .bind(request.source_id)
        .fetch_one(&mut *tx)
        .await?;
        if live > MAX_EXPORT_OBJECTS {
            return Err(ExportError::TooLarge);
        }
        let plan = plan_copy(&mut tx, request.source_id).await?;
        let channel = insert_channel_in_tx(
            &mut tx,
            &NewChannel {
                id: request.id,
                name: request.name,
                kind: CANVAS_CHANNEL_KIND,
                category_id: request.category_id,
                defaults: ChannelDefaults {
                    voice_enabled: request.voice_enabled,
                    ..ChannelDefaults::default()
                },
            },
            now,
        )
        .await?;
        copy_audience(&mut tx, &request, &source).await?;
        ensure_room(&mut tx, request.id, plan.order.len() as i64).await?;
        let edges = copy_objects(&mut tx, request.id, &plan, now).await?;
        attach_edges(&mut tx, request.id, &edges).await?;
        copy_side_rows(&mut tx, request.id).await?;
        let clear_op = match request.clear_source {
            true => Some(clear_source(self, &mut tx, &request, &plan.dropped).await?),
            false => None,
        };
        let left = match request.clear_source {
            true => plan.dropped.len() as i64,
            false => 0,
        };
        let (cleared, spared) = clear_op.as_ref().map_or((0, 0), |op| {
            (op.affected, op.spared_ids.len() as i64 - left)
        });
        let copied = plan.order.len() as i64;
        let skipped = plan.dropped.len() as i64;
        record_export(
            &mut tx,
            &request,
            clear_op.as_ref(),
            [copied, skipped, cleared, spared],
            now,
        )
        .await?;
        tx.commit().await?;
        Ok(CanvasExport {
            channel,
            fresh: true,
            copied,
            skipped,
            cleared,
            spared,
            left,
            clear_op: clear_op.filter(|op| op.affected > 0),
        })
    }
}

async fn source_of(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    source_id: ChannelId,
) -> Result<SourceRow, ExportError> {
    let channel = fetch_channel_by_id(&mut **tx, source_id).await?;
    let row: Option<SourceRow> = sqlx::query_as(
        "SELECT deleted_at IS NOT NULL AS deleted, permissions_synced AS synced \
         FROM channels WHERE id = ?",
    )
    .bind(source_id)
    .fetch_optional(&mut **tx)
    .await?;
    match (channel, row) {
        (Some(channel), Some(row))
            if !row.deleted && channel.kind != DM_CHANNEL_KIND && channel.canvas_open() =>
        {
            Ok(row)
        }
        _ => Err(ExportError::SourceUnavailable),
    }
}

/// The stored outcome when `request.id` already names this very export.
async fn replay_of(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &ExportRequest<'_>,
) -> Result<Option<CanvasExport>, ExportError> {
    let Some(existing) = fetch_channel_by_id(&mut **tx, request.id).await? else {
        return Ok(None);
    };
    let row: Option<ExportRow> = sqlx::query_as(
        "SELECT source_channel_id, clear_source, copied, skipped, cleared, spared \
         FROM canvas_exports WHERE channel_id = ?",
    )
    .bind(request.id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some(row) = row.filter(|row| {
        row.source_channel_id == request.source_id && row.clear_source == request.clear_source
    }) else {
        return Err(CreateChannelError::IdConflict.into());
    };
    let deleted: Option<i64> = sqlx::query_scalar("SELECT deleted_at FROM channels WHERE id = ?")
        .bind(request.id)
        .fetch_one(&mut **tx)
        .await?;
    if deleted.is_some() {
        return Err(CreateChannelError::Deleted.into());
    }
    Ok(Some(CanvasExport {
        channel: existing,
        fresh: false,
        copied: row.copied,
        skipped: row.skipped,
        cleared: row.cleared,
        spared: row.spared,
        left: if row.clear_source { row.skipped } else { 0 },
        clear_op: None,
    }))
}

/// Gives the copy exactly the source's audience (decision 0064): the category's rows while both stay synced, the source's own rows otherwise.
async fn copy_audience(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &ExportRequest<'_>,
    source: &SourceRow,
) -> Result<(), ExportError> {
    let source_category: Option<ChannelCategoryId> =
        sqlx::query_scalar("SELECT category_id FROM channels WHERE id = ?")
            .bind(request.source_id)
            .fetch_one(&mut **tx)
            .await?;
    match request.category_id {
        Some(category) if source.synced && source_category == Some(category) => {
            crate::store::category_overwrites::copy_category_overwrites(tx, request.id, category)
                .await?;
        }
        _ => {
            sqlx::query(
                "INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny) \
                 SELECT ?, target_type, target_id, allow, deny FROM channel_overwrites \
                 WHERE channel_id = ?",
            )
            .bind(request.id)
            .bind(request.source_id)
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(())
}

/// Clears everything the copy took; locked objects and the ones it could not copy stay.
async fn clear_source(
    store: &Store,
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &ExportRequest<'_>,
    left: &[CanvasObjectId],
) -> Result<SubmittedOp, ExportError> {
    let before_seq = current_canvas_seq(tx, request.source_id).await?;
    let now = store.now_ms_unique(tx).await?;
    Ok(clear_in_tx(
        tx,
        ClearInTx {
            channel_id: request.source_id,
            actor_id: request.actor_id,
            op_id: CanvasOpId::generate(),
            before_seq,
            scope: &ClearScope::default(),
            spare_locks: true,
            keep: left,
            now,
        },
    )
    .await?)
}

/// Stores the outcome as `[copied, skipped, cleared, spared]`, so a retry of this id answers it.
async fn record_export(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    request: &ExportRequest<'_>,
    clear_op: Option<&SubmittedOp>,
    counts: [i64; 4],
    now: i64,
) -> Result<(), sqlx::Error> {
    let [copied, skipped, cleared, spared] = counts;
    sqlx::query(
        "INSERT INTO canvas_exports \
         (channel_id, source_channel_id, clear_source, clear_op_id, copied, skipped, cleared, spared, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(request.id)
    .bind(request.source_id)
    .bind(request.clear_source)
    .bind(clear_op.map(|op| op.id))
    .bind(copied)
    .bind(skipped)
    .bind(cleared)
    .bind(spared)
    .bind(now)
    .execute(&mut **tx)
    .await?;
    Ok(())
}
