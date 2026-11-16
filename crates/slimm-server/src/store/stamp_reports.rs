// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reporting a picture stamped on the reporter's screen (decision 0121). The report is
//! about the sender, and every picture they stamped joins it while it is open.

use uuid::Uuid;

use super::reports::{FiledReport, ReportError};
use super::{Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// The subject kind of a report about pictures stamped on a screen; its subject is the sender.
pub const SCREEN_STAMP_KIND: &str = "screen_stamp";

impl Store {
    /// Files a report about whoever stamped `stamp_id`, or joins the reporter's open one
    /// about them, and links the stamp to it.
    ///
    /// Only the stamp's target may report it, and anyone else gets the same not-found as a
    /// stamp that never existed. Idempotent by the client's `id`, which names the report
    /// only when this call created it.
    pub async fn file_stamp_report(
        &self,
        id: Uuid,
        reporter: UserId,
        stamp_id: Uuid,
        reason: &str,
    ) -> Result<FiledReport, ReportError> {
        let mut tx = self.begin_write().await?;
        let stamp = sqlx::query!(
            r#"SELECT channel_id AS "channel_id!: ChannelId", sender_id AS "sender_id!: UserId",
                      target_id AS "target_id!: UserId"
               FROM screen_stamps WHERE id = ?"#,
            stamp_id
        )
        .fetch_optional(&mut *tx)
        .await?
        .filter(|stamp| stamp.target_id == reporter)
        .ok_or(ReportError::NotFound)?;
        let sender = stamp.sender_id;

        let named = sqlx::query!(
            r#"SELECT reporter_id AS "reporter_id?: UserId", subject_kind,
                      subject_id AS "subject_id: Uuid"
               FROM reports WHERE id = ?"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let open = sqlx::query_scalar!(
            r#"SELECT id AS "id!: Uuid" FROM reports
               WHERE reporter_id = ? AND subject_kind = ? AND subject_id = ?
                 AND resolved_at IS NULL"#,
            reporter,
            SCREEN_STAMP_KIND,
            sender
        )
        .fetch_optional(&mut *tx)
        .await?;
        let (report_id, created) = match (named, open) {
            (Some(row), _) => {
                let same = row.reporter_id == Some(reporter)
                    && row.subject_kind == SCREEN_STAMP_KIND
                    && row.subject_id == sender.0;
                if !same {
                    return Err(ReportError::IdConflict);
                }
                (id, false)
            }
            (None, Some(open)) => (open, false),
            (None, None) => {
                let now = now_ms();
                sqlx::query!(
                    "INSERT INTO reports
                        (id, reporter_id, subject_kind, subject_id, channel_id, reason,
                         snapshot, snapshot_author_id, created_at)
                     VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)",
                    id,
                    reporter,
                    SCREEN_STAMP_KIND,
                    sender,
                    stamp.channel_id,
                    reason,
                    sender,
                    now
                )
                .execute(&mut *tx)
                .await?;
                (id, true)
            }
        };
        let linked = sqlx::query!(
            "UPDATE screen_stamps SET report_id = ? WHERE id = ? AND report_id IS NOT ?",
            report_id,
            stamp_id,
            report_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        Ok(FiledReport {
            id: report_id,
            fresh: created || linked > 0,
        })
    }
}
