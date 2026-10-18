// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Operator-facing storage and sweep-health view: what is on disk, roughly
//! how much of it is reclaimable, which channels hold the most attachment
//! bytes, and when each background sweep last ran. See
//! `crates/slimm-server/src/http/storage.rs` for the route this backs.
//!
//! `database_bytes` and `database_reclaimable_bytes` come from SQLite's own
//! page accounting (`PRAGMA page_count` / `page_size` / `freelist_count`),
//! never from stat-ing the file or walking a directory: those pragmas are an
//! in-memory header read, while a `stat` can lie about a WAL-mode database
//! (the `-wal` file holds uncommitted pages) and a directory walk over the
//! attachments tree would cost O(files) on every read of this screen.
//! `attachment_bytes` reuses [`super::Store::total_attachment_bytes`], the
//! exact sum `/space/analytics` already reports, so the two views can never
//! disagree about what attachments hold.

use anyhow::Context;

use super::Store;
use crate::ids::ChannelId;

/// Most channels [`Store::attachment_bytes_by_channel`] ever returns in one
/// call; a caller may ask for fewer.
pub const MAX_STORAGE_CHANNEL_ROWS: i64 = 50;

/// The database's own page accounting: total size and how much of that a
/// `VACUUM` could reclaim.
pub struct DatabaseBytes {
    pub database_bytes: i64,
    pub database_reclaimable_bytes: i64,
}

/// One channel's share of total attachment bytes, from
/// [`Store::attachment_bytes_by_channel`].
pub struct ChannelStorage {
    pub channel_id: ChannelId,
    pub name: String,
    pub attachment_bytes: i64,
}

/// One background sweep's last recorded run, from [`Store::sweep_statuses`].
pub struct SweepStatus {
    pub name: String,
    pub last_run_at: i64,
    pub last_reclaimed: i64,
}

impl Store {
    /// The live database file's logical size and reclaimable space, read
    /// straight from SQLite's page header rather than the filesystem - see
    /// this module's own doc for why.
    ///
    /// Plain (non-macro) queries throughout: `PRAGMA` statements are not
    /// query-plan-analyzable the way `sqlx::query!` needs for its compile-time
    /// column-type check, so this reads them with an explicit turbofish
    /// instead of adding them to the offline cache.
    pub async fn database_bytes(&self) -> anyhow::Result<DatabaseBytes> {
        let page_count: i64 = sqlx::query_scalar("PRAGMA page_count")
            .fetch_one(&self.pool)
            .await
            .context("read page_count")?;
        let page_size: i64 = sqlx::query_scalar("PRAGMA page_size")
            .fetch_one(&self.pool)
            .await
            .context("read page_size")?;
        let freelist_count: i64 = sqlx::query_scalar("PRAGMA freelist_count")
            .fetch_one(&self.pool)
            .await
            .context("read freelist_count")?;
        Ok(DatabaseBytes {
            database_bytes: page_count * page_size,
            database_reclaimable_bytes: freelist_count * page_size,
        })
    }

    /// Total attachment bytes, deferring entirely to
    /// [`Store::total_attachment_bytes`] so this view and `/space/analytics`
    /// read the same number from the same query rather than two copies that
    /// could drift apart.
    pub async fn attachment_bytes_total(&self) -> anyhow::Result<i64> {
        self.total_attachment_bytes().await
    }

    /// The `limit` channels holding the most attachment bytes, heaviest
    /// first. DMs and threads are excluded - the same `kind != 'dm' AND
    /// parent_message_id IS NULL` scope `analytics_stats`'s own
    /// `channel_count` uses - so this never turns into a per-conversation
    /// storage breakdown of who is DMing whom, and a thread's bytes are
    /// counted in [`Store::attachment_bytes_total`] without being attributed
    /// to a named channel here.
    pub async fn attachment_bytes_by_channel(
        &self,
        limit: i64,
    ) -> anyhow::Result<Vec<ChannelStorage>> {
        let rows = sqlx::query!(
            r#"SELECT c.id AS "channel_id!: ChannelId", c.name AS "name!",
                      SUM(a.size + a.original_size) AS "bytes!: i64"
               FROM (SELECT DISTINCT m.channel_id, ma.sha256
                     FROM message_attachments ma
                     JOIN messages m ON m.id = ma.message_id
                     WHERE m.deleted_at IS NULL) per_channel
               JOIN attachments a ON a.sha256 = per_channel.sha256
               JOIN channels c ON c.id = per_channel.channel_id
               WHERE c.deleted_at IS NULL
                 AND c.kind != 'dm' AND c.parent_message_id IS NULL
               GROUP BY c.id
               ORDER BY "bytes!: i64" DESC
               LIMIT ?"#,
            limit
        )
        .fetch_all(&self.pool)
        .await
        .context("attachment bytes by channel")?;
        Ok(rows
            .into_iter()
            .map(|r| ChannelStorage {
                channel_id: r.channel_id,
                name: r.name,
                attachment_bytes: r.bytes,
            })
            .collect())
    }

    /// Records that a sweep ran just now, reclaiming `reclaimed` (a byte
    /// count, or another sweep-defined unit of work such as rows removed).
    /// Upserts so the table holds exactly one row per sweep name; callers
    /// treat a failure here as best-effort, since a sweep already committed
    /// its real work before this ever runs.
    pub async fn record_sweep_run(&self, name: &str, reclaimed: i64) -> anyhow::Result<()> {
        let now = super::now_ms();
        sqlx::query!(
            "INSERT INTO sweep_status (name, last_run_at, last_reclaimed) VALUES (?, ?, ?)
             ON CONFLICT (name) DO UPDATE SET
                 last_run_at = excluded.last_run_at,
                 last_reclaimed = excluded.last_reclaimed",
            name,
            now,
            reclaimed
        )
        .execute(&self.pool)
        .await
        .context("record sweep run")?;
        Ok(())
    }

    /// Every sweep that has recorded at least one run, in no particular
    /// order - the client sorts or labels these for display.
    pub async fn sweep_statuses(&self) -> anyhow::Result<Vec<SweepStatus>> {
        let rows = sqlx::query!(
            r#"SELECT name AS "name!", last_run_at AS "last_run_at!: i64",
                      last_reclaimed AS "last_reclaimed!: i64"
               FROM sweep_status"#
        )
        .fetch_all(&self.pool)
        .await
        .context("read sweep statuses")?;
        Ok(rows
            .into_iter()
            .map(|r| SweepStatus {
                name: r.name,
                last_run_at: r.last_run_at,
                last_reclaimed: r.last_reclaimed,
            })
            .collect())
    }
}
