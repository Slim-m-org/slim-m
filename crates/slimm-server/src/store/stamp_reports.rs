// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reporting a picture stamped on the reporter's screen (decision 0121). The report is
//! about the sender, and every picture they stamped joins it while it is open.

use sqlx::{QueryBuilder, Sqlite};
use uuid::Uuid;

use super::reports::{FiledReport, ReportError};
use super::{SCREEN_STAMP_TTL_MS, Store, now_ms};
use crate::ids::{ChannelId, UserId};

/// The subject kind of a report about pictures stamped on a screen; its subject is the sender.
pub const SCREEN_STAMP_KIND: &str = "screen_stamp";

/// The longest reason a report keeps, in characters.
pub const MAX_REASON_CHARS: usize = 2000;

/// The open report's reason with a new one from the same reporter on its own line, newest kept
/// whole when the two run past [`MAX_REASON_CHARS`]; `None` when it says nothing new.
fn joined_reason(stored: &str, added: &str) -> Option<String> {
    if added.is_empty() || stored.lines().any(|line| line == added) {
        return None;
    }
    let joined = format!("{stored}\n{added}");
    let excess = joined.chars().count().saturating_sub(MAX_REASON_CHARS);
    Some(joined.chars().skip(excess).collect())
}

/// Keeps a report off a moderator's queue and history unless they may see where it came from:
/// its channel, or for a stamp report spanning channels, one of its pictures' channels.
pub(super) fn push_hidden_channel_filter(
    builder: &mut QueryBuilder<Sqlite>,
    hidden_channels: &[ChannelId],
) {
    if hidden_channels.is_empty() {
        return;
    }
    let push_hidden = |builder: &mut QueryBuilder<Sqlite>| {
        let mut separated = builder.separated(", ");
        for channel_id in hidden_channels {
            separated.push_bind(*channel_id);
        }
    };
    builder.push(" AND (r.channel_id NOT IN (");
    push_hidden(builder);
    builder.push(") OR (r.channel_id IS NULL AND (r.subject_kind != ");
    builder.push_bind(SCREEN_STAMP_KIND);
    builder.push(" OR EXISTS (SELECT 1 FROM screen_stamps s WHERE s.report_id = r.id AND s.channel_id NOT IN (");
    push_hidden(builder);
    builder.push(")))))");
}

impl Store {
    /// Files a report about whoever stamped `stamp_id`, or joins the reporter's open one
    /// about them, and links the stamp and every other picture they stamped on the reporter's
    /// screen in the last day that no report holds yet.
    ///
    /// The report keeps the stamp's channel while every picture it holds came from there, and
    /// has none once they came from more, so the moderators of each channel see it; the queue
    /// shows each of them only the pictures from channels they moderate.
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
        let open = sqlx::query!(
            r#"SELECT id AS "id!: Uuid", reason AS "reason!" FROM reports
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
            (None, Some(open)) => {
                if let Some(joined) = joined_reason(&open.reason, reason) {
                    sqlx::query!(
                        "UPDATE reports SET reason = ? WHERE id = ?",
                        joined,
                        open.id
                    )
                    .execute(&mut *tx)
                    .await?;
                }
                (open.id, false)
            }
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
        let since = now_ms() - SCREEN_STAMP_TTL_MS;
        let linked = sqlx::query!(
            "UPDATE screen_stamps SET report_id = ?
             WHERE (id = ? AND report_id IS NOT ?)
                OR (target_id = ? AND sender_id = ? AND created_at >= ? AND report_id IS NULL)",
            report_id,
            stamp_id,
            report_id,
            reporter,
            sender,
            since
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        sqlx::query!(
            "UPDATE reports SET channel_id = NULL
             WHERE id = ? AND channel_id IS NOT NULL
               AND (SELECT COUNT(DISTINCT channel_id) FROM screen_stamps WHERE report_id = ?) > 1",
            report_id,
            report_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(FiledReport {
            id: report_id,
            fresh: created || linked > 0,
        })
    }

    /// The channels a stamp report's pictures came from; empty for any other report.
    pub async fn stamp_report_channels(&self, report_id: Uuid) -> anyhow::Result<Vec<ChannelId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT DISTINCT channel_id AS "channel_id!: ChannelId"
               FROM screen_stamps WHERE report_id = ?"#,
            report_id
        )
        .fetch_all(&self.pool)
        .await?)
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_REASON_CHARS, joined_reason};

    #[test]
    fn a_new_reason_joins_on_its_own_line_and_a_repeat_adds_nothing() {
        assert_eq!(
            joined_reason("spam", "worse"),
            Some("spam\nworse".to_owned())
        );
        assert_eq!(joined_reason("spam\nworse", "spam"), None);
        assert_eq!(joined_reason("spam", ""), None);
    }

    #[test]
    fn past_the_cap_the_oldest_words_go_first() {
        let stored = "a".repeat(MAX_REASON_CHARS);
        let joined = joined_reason(&stored, "newest").unwrap();
        assert_eq!(joined.chars().count(), MAX_REASON_CHARS);
        assert!(joined.ends_with("\nnewest"));
    }
}
