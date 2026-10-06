// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Space usage analytics: the recording toggle, and the stats it gates.
//!
//! Almost nothing here is stored. Total messages, messages per day, and the
//! active-hours histogram are computed on read straight from `messages`,
//! which already carries `created_at` for every row and was never a new
//! collection of data - it is the message store itself, coarsened into
//! counts. The one recorded series is process memory, sampled lazily on a
//! read of the analytics screen (never by a background timer) and pruned to
//! [`ANALYTICS_WINDOW_DAYS`] on every write, so a deployment that leaves the
//! toggle on but never opens the screen adds nothing to the idle process.
//!
//! Every query here is deliberately Space-wide, never per-author: an
//! aggregate count of messages sent in an hour is a usage stat, and a
//! per-member breakdown of when they personally were active is monitoring.
//! See `docs/decisions/0008-space-analytics.md` for where that line is drawn
//! and why.

use anyhow::Context;

use super::Store;
use super::now_ms;
use crate::ids::UserId;

/// How many trailing calendar days the derived breakdowns and the memory
/// series cover. Bounded so a long-lived deployment's history does not grow
/// either the read or the samples table without limit, and short enough that
/// "active hours" reflects recent use rather than a permanently frozen shape.
pub const ANALYTICS_WINDOW_DAYS: i64 = 30;
const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// The shortest gap between two recorded memory samples.
const SAMPLE_MIN_GAP_MS: i64 = 5 * 60 * 1000;

/// Most members [`Store::member_attachment_bytes`] reports on, heaviest
/// first, the same bounded-list shape `GET /presence` already uses.
const MAX_MEMBER_STORAGE_ROWS: i64 = 500;

/// One calendar day's message count, UTC, zero-filled for days with none.
pub struct DayCount {
    pub date: String,
    pub count: i64,
}

/// One recorded resident-memory reading.
pub struct MetricSample {
    pub sampled_at: i64,
    pub rss_bytes: i64,
}

/// One member's own attachment byte total, from [`Store::member_attachment_bytes`].
///
/// Deliberately not part of [`AnalyticsStats`]: that struct's own doc
/// promises never to name a member, and this is the one place in this file
/// that does, on purpose, for storage stewardship rather than usage
/// surveillance. See `docs/decisions/0008-space-analytics.md`.
pub struct MemberAttachmentUsage {
    pub user_id: UserId,
    /// The sum of every attachment this member has personally uploaded, by
    /// content hash. Two members who each uploaded the identical bytes are
    /// each charged the full size: this counts what a member contributed,
    /// not a share of deduplicated disk use.
    pub attachment_bytes: i64,
}

/// The whole answer [`Store::analytics_stats`] renders, all Space-wide.
pub struct AnalyticsStats {
    pub total_messages: i64,
    pub member_count: i64,
    pub channel_count: i64,
    pub attachment_bytes: i64,
    pub messages_by_day: Vec<DayCount>,
    /// Aggregate message count by UTC hour-of-day (0-23), summed across every
    /// author over the trailing window. Never broken out per member.
    pub active_hours: [i64; 24],
    pub memory_samples: Vec<MetricSample>,
}

impl Store {
    pub async fn analytics_enabled(&self) -> anyhow::Result<bool> {
        let value = sqlx::query_scalar!(
            r#"SELECT analytics_enabled AS "e!: i64" FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read analytics_enabled")?;
        Ok(value.unwrap_or(0) != 0)
    }

    /// Flips the toggle. Recorded memory samples are left in place either
    /// way: they carry no per-member content, and deleting them on every
    /// flip would punish an accidental untoggle more than it protects
    /// anything. Turning the screen back on picks its history back up.
    pub async fn set_analytics_enabled(&self, enabled: bool) -> anyhow::Result<()> {
        let now = now_ms();
        let value = i64::from(enabled);
        sqlx::query!(
            "UPDATE space_settings SET analytics_enabled = ?, updated_at = ? WHERE id = 1",
            value,
            now
        )
        .execute(&self.pool)
        .await
        .context("set analytics_enabled")?;
        Ok(())
    }

    /// Records one memory sample if at least [`SAMPLE_MIN_GAP_MS`] has passed
    /// since the last, then prunes anything older than the retention window.
    /// Safe to call on every analytics read: most calls are a no-op insert
    /// followed by a cheap prune against an already-empty range.
    pub async fn maybe_record_metrics_sample(&self, rss_bytes: i64) -> anyhow::Result<()> {
        let now = now_ms();
        let cutoff = now - ANALYTICS_WINDOW_DAYS * DAY_MS;
        let last = sqlx::query_scalar!(
            r#"SELECT sampled_at AS "t!: i64" FROM space_metrics_samples
               ORDER BY sampled_at DESC LIMIT 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read last metrics sample")?;
        if last.is_none_or(|t| now - t >= SAMPLE_MIN_GAP_MS) {
            sqlx::query!(
                "INSERT INTO space_metrics_samples (sampled_at, rss_bytes) VALUES (?, ?)",
                now,
                rss_bytes
            )
            .execute(&self.pool)
            .await
            .context("insert metrics sample")?;
        }
        sqlx::query!(
            "DELETE FROM space_metrics_samples WHERE sampled_at < ?",
            cutoff
        )
        .execute(&self.pool)
        .await
        .context("prune metrics samples")?;
        Ok(())
    }

    /// The full derived-plus-recorded answer. Callers gate this on
    /// [`Store::analytics_enabled`] themselves; this always computes, so it
    /// must never be reached for a deployment that has the toggle off.
    ///
    /// Two window starts, not one: `messages_by_day` groups by calendar date,
    /// an inclusive range that needs the `-1` to land on exactly
    /// [`ANALYTICS_WINDOW_DAYS`] rows and a start aligned to midnight UTC so
    /// the oldest bar counts its whole day, while `active_hours` and
    /// `memory_samples` filter a raw timestamp with `>=`, where the
    /// unadjusted start already covers the full window and the `-1` would
    /// instead drop them to 29 days.
    pub async fn analytics_stats(&self) -> anyhow::Result<AnalyticsStats> {
        let now = now_ms();
        let day_window_start =
            (now - (ANALYTICS_WINDOW_DAYS - 1) * DAY_MS).div_euclid(DAY_MS) * DAY_MS;
        let window_start = now - ANALYTICS_WINDOW_DAYS * DAY_MS;

        let total_messages = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "c!: i64" FROM messages WHERE deleted_at IS NULL"#
        )
        .fetch_one(&self.pool)
        .await
        .context("count messages")?;

        let member_count = self.member_count().await?;

        let channel_count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "c!: i64" FROM channels
               WHERE deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL"#
        )
        .fetch_one(&self.pool)
        .await
        .context("count channels")?;

        let attachment_bytes = self.total_attachment_bytes().await?;
        let messages_by_day = self.messages_by_day(day_window_start, now).await?;
        let active_hours = self.active_hours(window_start).await?;
        let memory_samples = self.memory_samples(window_start).await?;

        Ok(AnalyticsStats {
            total_messages,
            member_count,
            channel_count,
            attachment_bytes,
            messages_by_day,
            active_hours,
            memory_samples,
        })
    }

    /// One row per calendar day in `[window_start, now]`, zero-filled by the
    /// recursive CTE rather than in Rust, so a chart's x-axis is stable even
    /// for a Space that went quiet for a stretch.
    ///
    /// The counts come from one pass over the window's live messages, grouped
    /// by day, with the CTE joined against that aggregate - never the other
    /// way around: joining messages to the CTE on a function-wrapped
    /// `created_at` re-scanned every live message once per day row, thirty
    /// full scans per open of the analytics screen (the 2026-08-11 review's
    /// H5). One bounded pass is the same cost `active_hours` already pays.
    async fn messages_by_day(&self, window_start: i64, now: i64) -> anyhow::Result<Vec<DayCount>> {
        let rows = sqlx::query!(
            r#"WITH RECURSIVE days(day) AS (
                   SELECT date(?1 / 1000, 'unixepoch')
                   UNION ALL
                   SELECT date(day, '+1 day') FROM days WHERE day < date(?2 / 1000, 'unixepoch')
               ),
               counts(day, c) AS (
                   SELECT date(created_at / 1000, 'unixepoch'), COUNT(*)
                   FROM messages
                   WHERE deleted_at IS NULL AND created_at >= ?1
                   GROUP BY 1
               )
               SELECT days.day AS "day!: String", COALESCE(counts.c, 0) AS "c!: i64"
               FROM days
               LEFT JOIN counts ON counts.day = days.day
               ORDER BY days.day"#,
            window_start,
            now,
        )
        .fetch_all(&self.pool)
        .await
        .context("messages by day")?;
        Ok(rows
            .into_iter()
            .map(|r| DayCount {
                date: r.day,
                count: r.c,
            })
            .collect())
    }

    /// A 24-bucket histogram, aggregated across every author, never per one.
    async fn active_hours(&self, window_start: i64) -> anyhow::Result<[i64; 24]> {
        let rows = sqlx::query!(
            r#"SELECT CAST(strftime('%H', created_at / 1000, 'unixepoch') AS INTEGER) AS "hour!: i64",
                      COUNT(*) AS "c!: i64"
               FROM messages
               WHERE deleted_at IS NULL AND created_at >= ?
               GROUP BY strftime('%H', created_at / 1000, 'unixepoch')"#,
            window_start,
        )
        .fetch_all(&self.pool)
        .await
        .context("active hours")?;
        let mut hours = [0i64; 24];
        for row in rows {
            if let Ok(idx) = usize::try_from(row.hour)
                && idx < 24
            {
                hours[idx] = row.c;
            }
        }
        Ok(hours)
    }

    async fn memory_samples(&self, window_start: i64) -> anyhow::Result<Vec<MetricSample>> {
        let rows = sqlx::query!(
            r#"SELECT sampled_at AS "t!: i64", rss_bytes AS "r!: i64" FROM space_metrics_samples
               WHERE sampled_at >= ? ORDER BY sampled_at ASC"#,
            window_start,
        )
        .fetch_all(&self.pool)
        .await
        .context("read metrics samples")?;
        Ok(rows
            .into_iter()
            .map(|r| MetricSample {
                sampled_at: r.t,
                rss_bytes: r.r,
            })
            .collect())
    }

    /// Attachment bytes attributed to each member who has uploaded any,
    /// heaviest first, for the operator-facing storage-stewardship view -
    /// never the aggregate `stats` block, see [`MemberAttachmentUsage`].
    /// Callers gate this the same as [`Store::analytics_stats`]: it always
    /// computes, so it must never be reached while analytics is off.
    pub async fn member_attachment_bytes(&self) -> anyhow::Result<Vec<MemberAttachmentUsage>> {
        let rows = sqlx::query!(
            r#"SELECT u.uploaded_by AS "user_id!: UserId", SUM(a.size) AS "bytes!: i64"
               FROM attachment_uploaders u
               JOIN attachments a ON a.sha256 = u.sha256
               GROUP BY u.uploaded_by
               ORDER BY "bytes!: i64" DESC
               LIMIT ?"#,
            MAX_MEMBER_STORAGE_ROWS
        )
        .fetch_all(&self.pool)
        .await
        .context("member attachment bytes")?;
        Ok(rows
            .into_iter()
            .map(|r| MemberAttachmentUsage {
                user_id: r.user_id,
                attachment_bytes: r.bytes,
            })
            .collect())
    }
}
