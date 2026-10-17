// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A reporter's own, narrow view of a report they filed - split out of
//! `reports` (the MANAGE_MESSAGES-gated moderation queue) to stay under that
//! file's review budget, and because this route answers a genuinely
//! different question: "is my own report still open", not "what is in the
//! queue".
//!
//! No permission gate at all - the caller only ever sees their own filing,
//! enforced by [`crate::store::Store::reporter_own_report`] filtering on
//! `reporter_id` in the query itself, never by fetching a row and checking
//! ownership here. Never leaks which moderator handled a report or what they
//! did; that trail belongs to `reports::list` and `reports::history`, both
//! still gated on MANAGE_MESSAGES.

use axum::extract::{Path, State};
use serde::Serialize;

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::super::messages::parse_uuid;
use crate::store::ReporterOwnReport;

/// A reporter's own view of a report they filed, from [`my_report_status`].
/// Deliberately narrow: only what the reporter already gave when they filed
/// it (what they reported, and when) plus whether it has since closed.
/// Nothing here names a moderator, an action taken, or any other reporter's
/// report - see [`my_report_status`]'s own doc for why.
#[derive(Serialize)]
pub(in crate::http) struct MyReportStatusDto {
    id: String,
    subject_kind: String,
    subject_id: String,
    channel_id: Option<String>,
    created_at: i64,
    /// "open" or "resolved". Never the finer `resolved`/`dismissed` label a
    /// moderator's own resolution carries - that distinction is a judgment
    /// call about the report, not a fact the reporter is owed.
    status: &'static str,
}

impl From<ReporterOwnReport> for MyReportStatusDto {
    fn from(report: ReporterOwnReport) -> Self {
        Self {
            id: report.id.to_string(),
            subject_kind: report.subject_kind,
            subject_id: report.subject_id.to_string(),
            channel_id: report.channel_id.map(|id| id.to_string()),
            created_at: report.created_at,
            status: if report.resolved { "resolved" } else { "open" },
        }
    }
}

/// A reporter's own, narrow view of a report they filed: whether it is
/// still open, and nothing about who looked at it or what they did.
///
/// This is the one report-reading surface with no MANAGE_MESSAGES gate at
/// all - the caller only ever sees their own filing. A report id that
/// exists but was filed by someone else is answered identically to one
/// that never existed: both come back `None` from
/// [`crate::store::Store::reporter_own_report`], and both become this same
/// 404, per decision 0011's status-code masking rule.
pub(in crate::http) async fn my_report_status(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(report_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<MyReportStatusDto>, ApiError> {
    let report_id = parse_uuid(&report_id)?;
    let report = state
        .store
        .reporter_own_report(ctx.user_id, report_id)
        .await?
        .ok_or(ApiError::NotFound("report not found"))?;
    Ok(Json(MyReportStatusDto::from(report)))
}
