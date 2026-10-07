// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The moderation report queue: filing, paging, and resolving a report.
//!
//! Split out of `safety` (which keeps the device list and blocking) to stay
//! under the file's review budget; this is the safety surface with the most
//! going on, and it grew past that budget on its own.

use sqlx::QueryBuilder;
use uuid::Uuid;

use super::{Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

/// What a report is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportSubject {
    Message(MessageId),
    User(UserId),
}

impl ReportSubject {
    fn kind(&self) -> &'static str {
        match self {
            ReportSubject::Message(_) => "message",
            ReportSubject::User(_) => "user",
        }
    }

    fn id(&self) -> Uuid {
        match self {
            ReportSubject::Message(id) => id.0,
            ReportSubject::User(id) => id.0,
        }
    }
}

/// The subject kind a report about a bot's private message carries.
pub const EPHEMERAL_KIND: &str = "ephemeral_message";

/// What a reporter says a bot privately sent them, as the client showed it.
pub struct EphemeralSubject<'a> {
    pub message_id: MessageId,
    pub channel_id: ChannelId,
    pub author_id: UserId,
    pub snapshot: &'a str,
}

struct ReportRow<'a> {
    id: Uuid,
    reporter: UserId,
    kind: &'a str,
    subject_id: Uuid,
    channel_id: Option<ChannelId>,
    reason: &'a str,
    snapshot: Option<&'a str>,
    snapshot_author_id: Option<UserId>,
}

/// Why filing a report failed.
#[derive(Debug)]
pub enum ReportError {
    /// This reporter already has an open report about this subject.
    AlreadyOpen,
    /// The client-supplied id already names a report by someone else or about
    /// something else, so replaying it would hand back a foreign report.
    IdConflict,
    /// The subject does not exist, or is not visible to the reporter.
    NotFound,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReportError {
    fn from(err: sqlx::Error) -> Self {
        ReportError::Internal(err.into())
    }
}

/// A filed report, for the moderation queue. Carries the content snapshot, so
/// this type must never reach anyone below the MANAGE_MESSAGES bar.
#[derive(Debug, Clone)]
pub struct Report {
    pub id: Uuid,
    /// Null once the reporter's account has been anonymized.
    pub reporter_id: Option<UserId>,
    pub subject_kind: String,
    pub subject_id: Uuid,
    pub channel_id: Option<ChannelId>,
    pub reason: String,
    /// The reported content as it was at filing time; the author may have
    /// since edited or deleted it.
    pub snapshot: Option<String>,
    /// Who wrote the reported message, for a report about one.
    ///
    /// Joined at read time rather than stored beside the snapshot, because a
    /// report is filed about a message id and the authorship of that id does
    /// not change - only its content does, which is what the snapshot is for.
    /// Null for a report about a user (there is no message), for a message
    /// since hard-deleted, and once the author's account is anonymized.
    pub subject_author_id: Option<UserId>,
    pub created_at: i64,
    pub resolved_at: Option<i64>,
    pub resolved_by: Option<UserId>,
    pub resolution: Option<String>,
}

/// A reporter's own view of one report they filed: enough to know it was
/// received and whether it has since been closed, and nothing about who
/// looked at it or what they did about it. See
/// [`Store::reporter_own_report`] for how this stays scoped to its owner.
#[derive(Debug, Clone)]
pub struct ReporterOwnReport {
    pub id: Uuid,
    pub subject_kind: String,
    pub subject_id: Uuid,
    pub channel_id: Option<ChannelId>,
    pub created_at: i64,
    pub resolved: bool,
}

/// What filing a report produced: its id, and whether this call created it
/// (`fresh`) or replayed an earlier filing under the same client id.
#[derive(Debug, Clone, Copy)]
pub struct FiledReport {
    pub id: Uuid,
    pub fresh: bool,
}

impl Store {
    /// Files a report for a human to review, idempotent by the client-minted
    /// `id` the way every other durable write is: a retry with the same id from
    /// the same reporter about the same subject replays the report already
    /// stored rather than answering 409 for a filing the client cannot find.
    /// The same id naming a different reporter or subject is a conflict.
    ///
    /// A snapshot of the reported content is stored, because the author can edit
    /// or delete it afterwards and a report about something that no longer
    /// exists tells a moderator nothing.
    pub async fn file_report_with_id(
        &self,
        id: Uuid,
        reporter: UserId,
        subject: ReportSubject,
        reason: &str,
    ) -> Result<FiledReport, ReportError> {
        let (channel_id, snapshot) = match subject {
            ReportSubject::Message(message_id) => {
                let message = self
                    .message(message_id)
                    .await
                    .map_err(ReportError::Internal)?
                    .ok_or(ReportError::NotFound)?;
                (Some(message.channel_id), Some(message.content))
            }
            ReportSubject::User(_) => (None, None),
        };

        self.insert_report(ReportRow {
            id,
            reporter,
            kind: subject.kind(),
            subject_id: subject.id(),
            channel_id,
            reason,
            snapshot: snapshot.as_deref(),
            snapshot_author_id: None,
        })
        .await
    }

    /// Files a report about a bot's private message. Nothing stored names it,
    /// so the text and the bot are what the reporter says they saw; the caller
    /// has checked the bot is a bot and the reporter can view the channel.
    pub async fn file_ephemeral_report(
        &self,
        id: Uuid,
        reporter: UserId,
        subject: &EphemeralSubject<'_>,
        reason: &str,
    ) -> Result<FiledReport, ReportError> {
        self.insert_report(ReportRow {
            id,
            reporter,
            kind: EPHEMERAL_KIND,
            subject_id: subject.message_id.0,
            channel_id: Some(subject.channel_id),
            reason,
            snapshot: Some(subject.snapshot),
            snapshot_author_id: Some(subject.author_id),
        })
        .await
    }

    async fn insert_report(&self, row: ReportRow<'_>) -> Result<FiledReport, ReportError> {
        let ReportRow {
            id,
            reporter,
            kind,
            subject_id,
            channel_id: channel,
            reason,
            snapshot,
            snapshot_author_id,
        } = row;
        let now = now_ms();
        // Reads the id before deciding what to write; see Store::begin_write.
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query!(
            r#"SELECT reporter_id AS "reporter_id?: UserId", subject_kind,
                      subject_id AS "subject_id: Uuid"
               FROM reports WHERE id = ?"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = existing {
            tx.commit().await?;
            let same = row.reporter_id == Some(reporter)
                && row.subject_kind == kind
                && row.subject_id == subject_id;
            return if same {
                Ok(FiledReport { id, fresh: false })
            } else {
                Err(ReportError::IdConflict)
            };
        }

        let result = sqlx::query!(
            "INSERT INTO reports
                (id, reporter_id, subject_kind, subject_id, channel_id, reason,
                 snapshot, snapshot_author_id, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            id,
            reporter,
            kind,
            subject_id,
            channel,
            reason,
            snapshot,
            snapshot_author_id,
            now
        )
        .execute(&mut *tx)
        .await;

        match result {
            Ok(_) => {
                tx.commit().await?;
                Ok(FiledReport { id, fresh: true })
            }
            // One open report per subject per reporter, so this cannot flood the queue.
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
                Err(ReportError::AlreadyOpen)
            }
            Err(e) => Err(ReportError::Internal(e.into())),
        }
    }

    /// One page of the moderation queue: open reports, oldest first.
    ///
    /// Bounded, and filtered *before* the limit rather than after it. That
    /// ordering is the whole design here. A report carries the reported content
    /// verbatim, so the queue is filtered per channel; doing that after a
    /// `LIMIT` means a page can come back holding fewer entries than asked for,
    /// and a caller has no way to tell that from the end of the queue - so a
    /// moderator denied MANAGE_MESSAGES in one busy channel silently stops
    /// paging while reports they may read sit past the window. Excluding those
    /// channels in the `WHERE` makes a short page mean exactly one thing.
    ///
    /// `hidden_channels` is that exclusion, resolved once by the caller through
    /// [`Store::channels_where`] rather than a permission evaluation per row.
    /// It holds live non-DM channels the caller cannot moderate. A report with
    /// no channel, one about a DM, and one about a since-deleted channel are all
    /// outside it and stay visible on the caller's deployment-wide bit alone,
    /// which is what [`Store::channel_scopes_moderation`] answers per report.
    ///
    /// The cursor is composite - `(created_at, id)`, exclusive - and matches the
    /// ordering. A `created_at` alone cannot page correctly: it is milliseconds,
    /// so two reports can share one, and a boundary inside a tied group would
    /// skip every remaining member of it permanently rather than just one.
    pub async fn list_open_reports(
        &self,
        after: Option<(i64, Uuid)>,
        hidden_channels: &[ChannelId],
        limit: i64,
    ) -> anyhow::Result<Vec<Report>> {
        let mut builder = QueryBuilder::new(
            r#"SELECT r.id, r.reporter_id, r.subject_kind, r.subject_id, r.channel_id,
                      r.reason, r.snapshot, r.created_at, r.resolved_at, r.resolved_by,
                      r.resolution, COALESCE(m.author_id, r.snapshot_author_id) AS subject_author_id
               FROM reports r
               LEFT JOIN messages m
                 ON r.subject_kind = 'message' AND m.id = r.subject_id
               WHERE r.resolved_at IS NULL"#,
        );
        if let Some((created_at, id)) = after {
            builder.push(" AND (r.created_at > ");
            builder.push_bind(created_at);
            builder.push(" OR (r.created_at = ");
            builder.push_bind(created_at);
            builder.push(" AND r.id > ");
            builder.push_bind(id);
            builder.push("))");
        }
        if !hidden_channels.is_empty() {
            builder.push(" AND (r.channel_id IS NULL OR r.channel_id NOT IN (");
            let mut separated = builder.separated(", ");
            for channel_id in hidden_channels {
                separated.push_bind(*channel_id);
            }
            builder.push("))");
        }
        builder.push(" ORDER BY r.created_at, r.id LIMIT ");
        builder.push_bind(limit);

        use sqlx::Row;
        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| {
                Ok(Report {
                    id: row.try_get("id")?,
                    reporter_id: row.try_get("reporter_id")?,
                    subject_kind: row.try_get("subject_kind")?,
                    subject_id: row.try_get("subject_id")?,
                    channel_id: row.try_get("channel_id")?,
                    reason: row.try_get("reason")?,
                    snapshot: row.try_get("snapshot")?,
                    created_at: row.try_get("created_at")?,
                    subject_author_id: row.try_get("subject_author_id")?,
                    resolved_at: row.try_get("resolved_at")?,
                    resolved_by: row.try_get("resolved_by")?,
                    resolution: row.try_get("resolution")?,
                })
            })
            .collect()
    }

    /// The distinct channel ids named by a currently open report, thread or
    /// not.
    ///
    /// `http::reports::hidden_channels` needs this because a thread never
    /// appears in [`Store::list_channels`], so the exclusion it batches from
    /// that list cannot see one; this hands back exactly the ids worth
    /// resolving individually rather than every channel in the deployment.
    pub async fn open_report_channel_ids(&self) -> anyhow::Result<Vec<ChannelId>> {
        let rows = sqlx::query_scalar!(
            r#"SELECT DISTINCT channel_id AS "channel_id!: ChannelId"
               FROM reports WHERE resolved_at IS NULL AND channel_id IS NOT NULL"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// The distinct channel ids named by ANY report, open or resolved,
    /// thread or not.
    ///
    /// The history feed's own `http::reports::hidden_channels` call needs this
    /// rather than `Self::open_report_channel_ids`: a resolved report still
    /// carries its content snapshot, so a thread whose only report has since
    /// been resolved must still be checked against the caller's `VIEW_CHANNEL`
    /// on its parent - `open_report_channel_ids` stops naming that thread the
    /// instant its report closes, which is exactly the gap that let a
    /// resolved report from a thread under a hidden parent leak into the
    /// history feed.
    pub async fn report_channel_ids_including_resolved(&self) -> anyhow::Result<Vec<ChannelId>> {
        let rows = sqlx::query_scalar!(
            r#"SELECT DISTINCT channel_id AS "channel_id!: ChannelId"
               FROM reports WHERE channel_id IS NOT NULL"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// The channel an open report is about, if it is about a message at all.
    ///
    /// `Ok(None)` means no open report by that id; `Ok(Some(None))` means one
    /// exists and is deployment-wide (a report about a person, not a message).
    /// Callers use it to apply the same per-channel gate the queue listing
    /// applies before acting on a report.
    pub async fn open_report_channel(
        &self,
        report_id: Uuid,
    ) -> anyhow::Result<Option<Option<ChannelId>>> {
        let row = sqlx::query!(
            r#"SELECT channel_id AS "channel_id: ChannelId"
               FROM reports WHERE id = ? AND resolved_at IS NULL"#,
            report_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| r.channel_id))
    }

    /// Whether any report, open or closed, has this id.
    pub async fn report_exists(&self, report_id: Uuid) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM reports WHERE id = ?"#,
            report_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// Resolves or dismisses an open report. `resolution` is a short caller-
    /// supplied label ("resolved" or "dismissed"); the distinction is not
    /// enforced here, since both are just a moderator's disposition on the
    /// same claim-first close.
    ///
    /// The UPDATE is conditional on `resolved_at IS NULL`, so two moderators
    /// racing the same report cannot both "win" it, and returns whether this
    /// call was the one that closed it: `false` covers both an unknown report
    /// and one already resolved, which the caller treats the same way.
    pub async fn resolve_report(
        &self,
        report_id: Uuid,
        resolved_by: UserId,
        resolution: &str,
    ) -> anyhow::Result<bool> {
        let now = now_ms();
        let affected = sqlx::query!(
            "UPDATE reports SET resolved_at = ?, resolved_by = ?, resolution = ?
             WHERE id = ? AND resolved_at IS NULL",
            now,
            resolved_by,
            resolution,
            report_id
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(affected > 0)
    }

    /// A report by id, scoped to the reporter who filed it - `http::reports`'s
    /// narrow, status-only read for someone checking on their own filing.
    ///
    /// Filters on `reporter_id` in the query itself rather than fetching by id
    /// and checking ownership in Rust afterward, so there is no code path that
    /// ever holds a row this reporter does not own. `Ok(None)` covers both a
    /// report that does not exist and one that exists but was filed by someone
    /// else - the caller must answer both with the same 404, per decision
    /// 0011's status-code masking rule, and cannot do that correctly unless
    /// this function has already made the two indistinguishable.
    ///
    /// Once the reporter's account is anonymized, `reports.reporter_id` is set
    /// to NULL (0005's `ON DELETE SET NULL`), so this stops matching on its
    /// own; there is nobody left to ask for it anyway.
    pub async fn reporter_own_report(
        &self,
        reporter_id: UserId,
        report_id: Uuid,
    ) -> anyhow::Result<Option<ReporterOwnReport>> {
        let row = sqlx::query!(
            r#"SELECT subject_kind, subject_id AS "subject_id!: Uuid",
                      channel_id AS "channel_id: ChannelId", created_at,
                      (resolved_at IS NOT NULL) AS "resolved!: bool"
               FROM reports WHERE id = ? AND reporter_id = ?"#,
            report_id,
            reporter_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| ReporterOwnReport {
            id: report_id,
            subject_kind: r.subject_kind,
            subject_id: r.subject_id,
            channel_id: r.channel_id,
            created_at: r.created_at,
            resolved: r.resolved,
        }))
    }
}
