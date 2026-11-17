// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pictures stamped on a shared screen (decision 0121): one row per picture, which is
//! the fetch grant, the hold against the orphan sweep and what a report points at.

use std::collections::HashMap;

use sqlx::QueryBuilder;
use uuid::Uuid;

use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// How long a stamped picture stays fetchable and listed, unless an open report holds it.
pub const SCREEN_STAMP_TTL_MS: i64 = 24 * 60 * 60 * 1000;

/// Most rows one sweep statement deletes, so the write lock is never held for long.
const SWEEP_BATCH: i64 = 500;

/// Most batches one sweep pass runs; the next hourly pass takes the rest.
const SWEEP_MAX_BATCHES: usize = 20;

/// One stored picture stamp.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenStamp {
    pub id: Uuid,
    pub channel_id: ChannelId,
    pub sender_id: UserId,
    pub target_id: UserId,
    pub sha256: Vec<u8>,
    pub report_id: Option<Uuid>,
    pub created_at: i64,
}

/// One person who stamped pictures on a screen in the window, by their latest picture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StampSender {
    pub latest: ScreenStamp,
    /// How many pictures they stamped in the window.
    pub sent: i64,
    /// How many of those no report holds yet.
    pub unreported: i64,
}

/// A picture a report carries, and the channel it was stamped in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportPicture {
    pub attachment_id: String,
    pub channel_id: ChannelId,
}

/// A picture stamp about to be stored.
pub struct NewScreenStamp<'a> {
    pub id: Uuid,
    pub channel_id: ChannelId,
    pub sender_id: UserId,
    pub target_id: UserId,
    pub sha256: &'a [u8],
}

/// What storing a picture stamp did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StampInsert {
    Fresh,
    /// The same stamp was already stored under this id.
    Replay,
    /// The id already names a different stamp.
    Conflict,
    /// The picture, the channel or a person went away between the checks and the write.
    Gone,
}

impl Store {
    /// Stores a picture stamp, idempotent by id.
    pub async fn insert_screen_stamp(
        &self,
        stamp: &NewScreenStamp<'_>,
    ) -> anyhow::Result<StampInsert> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query!(
            r#"SELECT channel_id AS "channel_id!: ChannelId", sender_id AS "sender_id!: UserId",
                      target_id AS "target_id!: UserId", sha256 AS "sha256!: Vec<u8>"
               FROM screen_stamps WHERE id = ?"#,
            stamp.id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = existing {
            tx.commit().await?;
            let same = row.channel_id == stamp.channel_id
                && row.sender_id == stamp.sender_id
                && row.target_id == stamp.target_id
                && row.sha256 == stamp.sha256;
            return Ok(if same {
                StampInsert::Replay
            } else {
                StampInsert::Conflict
            });
        }
        let inserted = sqlx::query!(
            "INSERT INTO screen_stamps (id, channel_id, sender_id, target_id, sha256, created_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            stamp.id,
            stamp.channel_id,
            stamp.sender_id,
            stamp.target_id,
            stamp.sha256,
            now
        )
        .execute(&mut *tx)
        .await;
        match inserted {
            Ok(_) => {
                tx.commit().await?;
                Ok(StampInsert::Fresh)
            }
            Err(sqlx::Error::Database(e)) if e.is_foreign_key_violation() => Ok(StampInsert::Gone),
            Err(e) => Err(e.into()),
        }
    }

    /// One stored picture stamp by id, of any age.
    pub async fn screen_stamp(&self, id: Uuid) -> anyhow::Result<Option<ScreenStamp>> {
        let row = sqlx::query_as!(
            ScreenStamp,
            r#"SELECT id AS "id!: Uuid", channel_id AS "channel_id!: ChannelId",
                      sender_id AS "sender_id!: UserId", target_id AS "target_id!: UserId",
                      sha256 AS "sha256!: Vec<u8>", report_id AS "report_id?: Uuid",
                      created_at AS "created_at!"
               FROM screen_stamps WHERE id = ?"#,
            id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// Everyone who stamped a picture on `target`'s screen since `since`, by their latest one:
    /// those with a picture no report holds first, then newest first.
    ///
    /// Uncapped, so no number of senders pushes one off; the community bounds how many there are.
    pub async fn screen_stamp_senders(
        &self,
        target: UserId,
        since: i64,
    ) -> anyhow::Result<Vec<StampSender>> {
        let rows = sqlx::query!(
            r#"SELECT id AS "id!: Uuid", channel_id AS "channel_id!: ChannelId",
                      sender_id AS "sender_id!: UserId", target_id AS "target_id!: UserId",
                      sha256 AS "sha256!: Vec<u8>", report_id AS "report_id?: Uuid",
                      created_at AS "created_at!", sent AS "sent!: i64",
                      unreported AS "unreported!: i64"
               FROM (
                   SELECT id, channel_id, sender_id, target_id, sha256, report_id, created_at,
                          ROW_NUMBER() OVER (
                              PARTITION BY sender_id ORDER BY created_at DESC, id DESC
                          ) AS place,
                          COUNT(*) OVER (PARTITION BY sender_id) AS sent,
                          SUM(report_id IS NULL) OVER (PARTITION BY sender_id) AS unreported
                   FROM screen_stamps WHERE target_id = ? AND created_at >= ?
               )
               WHERE place = 1
               ORDER BY unreported = 0, created_at DESC, id DESC"#,
            target,
            since
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|row| StampSender {
                sent: row.sent,
                unreported: row.unreported,
                latest: ScreenStamp {
                    id: row.id,
                    channel_id: row.channel_id,
                    sender_id: row.sender_id,
                    target_id: row.target_id,
                    sha256: row.sha256,
                    report_id: row.report_id,
                    created_at: row.created_at,
                },
            })
            .collect())
    }

    /// The pictures `sender` stamped on `target`'s screen since `since`, newest first.
    pub async fn screen_stamps_from(
        &self,
        target: UserId,
        sender: UserId,
        since: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<ScreenStamp>> {
        let rows = sqlx::query_as!(
            ScreenStamp,
            r#"SELECT id AS "id!: Uuid", channel_id AS "channel_id!: ChannelId",
                      sender_id AS "sender_id!: UserId", target_id AS "target_id!: UserId",
                      sha256 AS "sha256!: Vec<u8>", report_id AS "report_id?: Uuid",
                      created_at AS "created_at!"
               FROM screen_stamps WHERE target_id = ? AND sender_id = ? AND created_at >= ?
               ORDER BY created_at DESC, id DESC LIMIT ?"#,
            target,
            sender,
            since,
            limit
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Whether `user` sent or received a stamp of this picture made since `since`.
    pub async fn stamp_party_since(
        &self,
        sha256: &[u8],
        user: UserId,
        since: i64,
    ) -> anyhow::Result<bool> {
        let found = sqlx::query_scalar!(
            r#"SELECT EXISTS(
                   SELECT 1 FROM screen_stamps
                   WHERE sha256 = ? AND created_at >= ? AND (target_id = ? OR sender_id = ?)
               ) AS "found!: bool""#,
            sha256,
            since,
            user,
            user
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(found)
    }

    /// The channels where a stamp of this picture is linked to a report.
    pub async fn reported_stamp_channels(&self, sha256: &[u8]) -> anyhow::Result<Vec<ChannelId>> {
        let channels = sqlx::query_scalar!(
            r#"SELECT DISTINCT channel_id AS "channel_id!: ChannelId" FROM screen_stamps
               WHERE sha256 = ? AND report_id IS NOT NULL"#,
            sha256
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(channels)
    }

    /// The channels where this picture was stamped since `since`.
    pub async fn stamp_channels_since(
        &self,
        sha256: &[u8],
        since: i64,
    ) -> anyhow::Result<Vec<ChannelId>> {
        let channels = sqlx::query_scalar!(
            r#"SELECT DISTINCT channel_id AS "channel_id!: ChannelId" FROM screen_stamps
               WHERE sha256 = ? AND created_at >= ?"#,
            sha256,
            since
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(channels)
    }

    /// The pictures each of these reports carries, with where each was stamped, oldest first.
    pub async fn pictures_for_reports(
        &self,
        report_ids: &[Uuid],
    ) -> anyhow::Result<HashMap<Uuid, Vec<ReportPicture>>> {
        let mut out: HashMap<Uuid, Vec<ReportPicture>> = HashMap::new();
        if report_ids.is_empty() {
            return Ok(out);
        }
        let mut query = QueryBuilder::new(
            "SELECT report_id, sha256, channel_id FROM screen_stamps WHERE report_id IN (",
        );
        let mut ids = query.separated(", ");
        for id in report_ids {
            ids.push_bind(*id);
        }
        query.push(") ORDER BY created_at, id");
        let rows: Vec<(Uuid, Vec<u8>, ChannelId)> =
            query.build_query_as().fetch_all(&self.pool).await?;
        for (report_id, sha256, channel_id) in rows {
            let picture = ReportPicture {
                attachment_id: crate::media::to_hex(&sha256),
                channel_id,
            };
            let pictures = out.entry(report_id).or_default();
            if !pictures.contains(&picture) {
                pictures.push(picture);
            }
        }
        Ok(out)
    }

    /// Deletes stamps made before `cutoff` that no open report holds, returning how many went.
    ///
    /// The orphan sweep that runs after it reclaims each picture nothing else holds.
    pub async fn sweep_screen_stamps(&self, cutoff: i64) -> anyhow::Result<u64> {
        let mut swept = 0;
        for _ in 0..SWEEP_MAX_BATCHES {
            let deleted = sqlx::query!(
                "DELETE FROM screen_stamps WHERE id IN (
                     SELECT s.id FROM screen_stamps s
                     LEFT JOIN reports r ON r.id = s.report_id
                     WHERE s.created_at < ?
                       AND (s.report_id IS NULL OR r.id IS NULL OR r.resolved_at IS NOT NULL)
                     LIMIT ?
                 )",
                cutoff,
                SWEEP_BATCH
            )
            .execute(&self.pool)
            .await?
            .rows_affected();
            swept += deleted;
            if deleted < SWEEP_BATCH as u64 {
                break;
            }
        }
        Ok(swept)
    }
}
