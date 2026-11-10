// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MOD4: the owner-visible moderation-history feed - resolved reports and
//! `moderation_audit_log` rows, merged into one time-ordered, paginated read.
//!
//! The two sources are fetched separately and merged in Rust rather than
//! joined with one `UNION ALL`: a resolved report is filtered per channel the
//! same way [`super::Store::list_open_reports`] filters the open queue (it
//! still carries the reported content snapshot), while an audit row is
//! deployment-wide and carries no channel at all - decision 0011's shape for
//! member moderation. A single query would need to express both `WHERE`
//! clauses at once for no shared benefit.
//!
//! `moderation_audit_log_created_at` (migration 0068) serves the bare `created_at DESC, id DESC`
//! scan, so each source's top `limit` is an index read bounded by `LIMIT`.
//!
//! Pagination fetches the top `limit` rows from each source and merges them,
//! which is enough by the standard top-k-per-source argument: any row
//! belonging in the true top `limit` of the merged page can have at most
//! `limit - 1` rows ranked above it in the *whole* merge, so at most that many
//! from its *own* source, which means it is always within that source's own
//! top `limit`. The source matching the cursor's own kind is filtered with
//! the exact `(time, id)` composite [`super::Store::list_open_reports`]
//! already uses; the other source is filtered only on a time ceiling, since
//! two rows can only collide on the exact same instant *and* the same kind
//! when they are the same row - two different kinds sharing one timestamp
//! resolve deterministically by kind and need no id to disambiguate. See
//! [`tie_key`].

use sqlx::{QueryBuilder, Row};
use uuid::Uuid;

use super::Store;
use super::reports::Report;
use crate::ids::{ChannelId, UserId};

/// One `moderation_audit_log` row, read back for the history feed. Never
/// carries a channel: member moderation is deployment-wide, so there is
/// nothing here to mask per viewer beyond the route's own MANAGE_MESSAGES
/// gate.
#[derive(Debug, Clone)]
pub struct AuditLogEntry {
    pub id: i64,
    /// Null once the actor's account has been anonymized.
    pub actor_id: Option<UserId>,
    pub subject_id: UserId,
    pub action: String,
    pub reason: Option<String>,
    pub until: Option<i64>,
    pub created_at: i64,
}

/// One entry in the merged feed.
///
/// A tagged enum rather than a shared struct, so the HTTP DTO built over it
/// cannot blur a report's content snapshot with an audit row that never
/// carried one - the two sources are answering different questions and the
/// type says so.
#[derive(Debug, Clone)]
pub enum ModerationHistoryItem {
    ResolvedReport(Report),
    Audit(AuditLogEntry),
}

/// The page boundary: which kind the last-seen item was, and its own
/// composite key within that kind.
#[derive(Debug, Clone, Copy)]
pub enum HistoryCursor {
    Report { resolved_at: i64, id: Uuid },
    Audit { created_at: i64, id: i64 },
}

impl HistoryCursor {
    fn event_time(&self) -> i64 {
        match *self {
            HistoryCursor::Report { resolved_at, .. } => resolved_at,
            HistoryCursor::Audit { created_at, .. } => created_at,
        }
    }
}

/// The event time the feed orders by: a resolved report's `resolved_at`, an
/// audit row's `created_at`.
fn event_time(item: &ModerationHistoryItem) -> i64 {
    match item {
        ModerationHistoryItem::ResolvedReport(report) => report
            .resolved_at
            .expect("resolved_reports_page only returns rows with resolved_at set"),
        ModerationHistoryItem::Audit(entry) => entry.created_at,
    }
}

/// The stable tiebreak within one instant: a one-letter source prefix (so two
/// different kinds never compare their ids against each other) plus the
/// row's own id, formatted so lexical order matches the id's natural order -
/// a UUIDv7's hex text sorts the same as the UUID itself, and the audit
/// rowid is zero-padded because it is always positive.
fn tie_key(item: &ModerationHistoryItem) -> String {
    match item {
        ModerationHistoryItem::ResolvedReport(report) => format!("R{}", report.id.simple()),
        ModerationHistoryItem::Audit(entry) => format!("A{:020}", entry.id),
    }
}

fn cursor_tie_key(cursor: HistoryCursor) -> String {
    match cursor {
        HistoryCursor::Report { id, .. } => format!("R{}", id.simple()),
        HistoryCursor::Audit { id, .. } => format!("A{id:020}"),
    }
}

impl Store {
    /// One page of the merged moderation-history feed, newest first.
    ///
    /// `hidden_channels` is applied only to the resolved-report side, the
    /// same exclusion [`Store::list_open_reports`] applies to the open queue;
    /// an audit row has no channel to filter.
    pub async fn moderation_history(
        &self,
        after: Option<HistoryCursor>,
        hidden_channels: &[ChannelId],
        limit: i64,
    ) -> anyhow::Result<Vec<ModerationHistoryItem>> {
        let (report_exact, report_ceiling) = match after {
            Some(HistoryCursor::Report { resolved_at, id }) => (Some((resolved_at, id)), None),
            Some(other) => (None, Some(other.event_time())),
            None => (None, None),
        };
        let (audit_exact, audit_ceiling) = match after {
            Some(HistoryCursor::Audit { created_at, id }) => (Some((created_at, id)), None),
            Some(other) => (None, Some(other.event_time())),
            None => (None, None),
        };

        let reports = self
            .resolved_reports_page(report_exact, report_ceiling, hidden_channels, limit)
            .await?;
        let audit = self
            .audit_log_page(audit_exact, audit_ceiling, limit)
            .await?;

        let mut merged: Vec<ModerationHistoryItem> = reports
            .into_iter()
            .map(ModerationHistoryItem::ResolvedReport)
            .chain(audit.into_iter().map(ModerationHistoryItem::Audit))
            .collect();

        // The cross-kind fetch above is a superset (bounded on time alone); this is where the exact boundary is enforced.
        if let Some(cursor) = after {
            let cursor_time = cursor.event_time();
            let cursor_tie = cursor_tie_key(cursor);
            merged.retain(|item| {
                (event_time(item), tie_key(item).as_str()) < (cursor_time, cursor_tie.as_str())
            });
        }

        merged.sort_by(|a, b| {
            event_time(b)
                .cmp(&event_time(a))
                .then_with(|| tie_key(b).cmp(&tie_key(a)))
        });
        merged.truncate(limit.max(0) as usize);
        Ok(merged)
    }

    /// Resolved reports only, newest-resolved first - the mirror image of
    /// [`Store::list_open_reports`]'s open-queue query.
    async fn resolved_reports_page(
        &self,
        exact: Option<(i64, Uuid)>,
        time_ceiling: Option<i64>,
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
               WHERE r.resolved_at IS NOT NULL"#,
        );
        if let Some((resolved_at, id)) = exact {
            builder.push(" AND (r.resolved_at < ");
            builder.push_bind(resolved_at);
            builder.push(" OR (r.resolved_at = ");
            builder.push_bind(resolved_at);
            builder.push(" AND r.id < ");
            builder.push_bind(id);
            builder.push("))");
        } else if let Some(ceiling) = time_ceiling {
            builder.push(" AND r.resolved_at <= ");
            builder.push_bind(ceiling);
        }
        if !hidden_channels.is_empty() {
            builder.push(" AND (r.channel_id IS NULL OR r.channel_id NOT IN (");
            let mut separated = builder.separated(", ");
            for channel_id in hidden_channels {
                separated.push_bind(*channel_id);
            }
            builder.push("))");
        }
        builder.push(" ORDER BY r.resolved_at DESC, r.id DESC LIMIT ");
        builder.push_bind(limit);

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
                    subject_author_id: row.try_get("subject_author_id")?,
                    created_at: row.try_get("created_at")?,
                    resolved_at: row.try_get("resolved_at")?,
                    resolved_by: row.try_get("resolved_by")?,
                    resolution: row.try_get("resolution")?,
                })
            })
            .collect()
    }

    /// Audit rows only, newest first.
    async fn audit_log_page(
        &self,
        exact: Option<(i64, i64)>,
        time_ceiling: Option<i64>,
        limit: i64,
    ) -> anyhow::Result<Vec<AuditLogEntry>> {
        let mut builder = QueryBuilder::new(
            "SELECT id, actor_id, subject_id, action, reason, until, created_at
             FROM moderation_audit_log WHERE 1 = 1",
        );
        if let Some((created_at, id)) = exact {
            builder.push(" AND (created_at < ");
            builder.push_bind(created_at);
            builder.push(" OR (created_at = ");
            builder.push_bind(created_at);
            builder.push(" AND id < ");
            builder.push_bind(id);
            builder.push("))");
        } else if let Some(ceiling) = time_ceiling {
            builder.push(" AND created_at <= ");
            builder.push_bind(ceiling);
        }
        builder.push(" ORDER BY created_at DESC, id DESC LIMIT ");
        builder.push_bind(limit);

        let rows = builder.build().fetch_all(&self.pool).await?;
        rows.into_iter()
            .map(|row| {
                Ok(AuditLogEntry {
                    id: row.try_get("id")?,
                    actor_id: row.try_get("actor_id")?,
                    subject_id: row.try_get("subject_id")?,
                    action: row.try_get("action")?,
                    reason: row.try_get("reason")?,
                    until: row.try_get("until")?,
                    created_at: row.try_get("created_at")?,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::{HistoryCursor, cursor_tie_key};
    use uuid::Uuid;

    /// The audit key is zero-padded so a plain string comparison matches the
    /// numeric order of the id: without it "A9" would sort after "A10" and
    /// pagination would skip or repeat rows at the boundary.
    #[test]
    fn an_audit_tie_key_is_zero_padded_for_string_order() {
        let nine = cursor_tie_key(HistoryCursor::Audit {
            created_at: 0,
            id: 9,
        });
        let ten = cursor_tie_key(HistoryCursor::Audit {
            created_at: 0,
            id: 10,
        });
        assert!(nine < ten, "{nine} should sort before {ten}");
        assert_eq!(nine, "A00000000000000000009");
    }

    /// A report key carries the uuid, and its prefix keeps it from ever
    /// colliding with an audit key at the same event time.
    #[test]
    fn a_report_tie_key_carries_the_uuid_under_a_distinct_prefix() {
        let id = Uuid::from_u128(0x1234_5678);
        let report = cursor_tie_key(HistoryCursor::Report { resolved_at: 0, id });
        assert_eq!(report, format!("R{}", id.simple()));

        let audit = cursor_tie_key(HistoryCursor::Audit {
            created_at: 0,
            id: 0,
        });
        assert_ne!(report.chars().next(), audit.chars().next());
    }
}
