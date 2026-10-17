// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Report triage: the moderation queue over what [`super::safety::file_report`]
//! intakes.
//!
//! Gated on MANAGE_MESSAGES at the deployment level. A report carries a
//! snapshot of the reported content (see [`crate::store::Report`]), so this
//! surface must never answer to anyone below that bar; every moderation
//! handler here checks it before touching the store, the same as the rest of
//! this file's sibling admin surfaces do. [`history`] alone also accepts the
//! read-only `VIEW_MODERATION_HISTORY`; see that handler's own doc.
//!
//! [`self::reports_mine::my_report_status`] is the one exception, split into
//! its own file rather than added here, and deliberately so: it is not a
//! smaller version of the moderation queue, it is a different question
//! altogether ("is my own report still open", not "what is in the queue"),
//! scoped by `reporter_id` rather than by permission. It never carries a
//! snapshot, a reporter's identity beyond their own, or anything about who
//! moderated a report or how.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch};
use serde::{Deserialize, Serialize};

use self::reports_cursor::parse_history_cursor;
use self::reports_guards::{missing_or_closed, require_manage_messages};
use self::reports_mine::my_report_status;
use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{ModerationHistoryItem, Report};

pub(super) mod reports_cursor;
pub(super) mod reports_guards;
pub(super) mod reports_mine;

const BODY_LIMIT: usize = 4 * 1024;

/// Default and maximum reports returned in one page, matching the plain
/// message list's shape. A page is bounded because the handler pays several
/// indexed queries per report to re-check visibility, and nothing else bounds
/// how many reports members file.
const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 200;

/// The report triage routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/reports", get(list))
        .route("/reports/history", get(history))
        .route("/reports/mine/{report_id}", get(my_report_status))
        .route("/reports/{report_id}", patch(resolve))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize)]
struct ReportDto {
    id: String,
    /// Null once the reporter's account has been anonymized.
    reporter_id: Option<String>,
    subject_kind: String,
    subject_id: String,
    channel_id: Option<String>,
    reason: String,
    /// The reported content as it stood at filing time; the author may have
    /// since edited or deleted it. Absent from every route below the
    /// MANAGE_MESSAGES bar.
    snapshot: Option<String>,
    /// Who wrote the reported message. Null for a report about a user, for a
    /// message since hard-deleted, and once the author is anonymized.
    subject_author_id: Option<String>,
    created_at: i64,
    /// The caller's effective permissions in `channel_id`, or null exactly
    /// when `channel_id` itself is null. A report's channel does not by
    /// itself say whether the caller can currently manage it - it could be
    /// a DM (never manageable, by design), a deleted channel (nothing left
    /// to manage), or a live channel the caller already holds
    /// MANAGE_MESSAGES in (or the report would have been filtered out
    /// before it reached this page). Populated once per page in `list`,
    /// batched through `Store::permissions_in_channels`, and masked the
    /// same way `GET /channels/{channelId}/permissions` masks its own
    /// answer - a DM report's own bitmask structurally never carries
    /// MANAGE_MESSAGES, since a DM has no such permission for anyone.
    channel_permissions: Option<i64>,
}

impl From<Report> for ReportDto {
    fn from(report: Report) -> Self {
        Self {
            id: report.id.to_string(),
            reporter_id: report.reporter_id.map(|id| id.to_string()),
            subject_kind: report.subject_kind,
            subject_id: report.subject_id.to_string(),
            channel_id: report.channel_id.map(|id| id.to_string()),
            reason: report.reason,
            snapshot: report.snapshot,
            subject_author_id: report.subject_author_id.map(|id| id.to_string()),
            created_at: report.created_at,
            channel_permissions: None,
        }
    }
}

/// One page of the queue. The cursor is the `created_at` and `id` of the last
/// report the caller already holds, exclusive and composite: `created_at` is
/// milliseconds, so two reports can share one, and a cursor on the timestamp
/// alone would skip every remaining member of a tied group that a page boundary
/// fell inside. Both or neither - an `after` without an `after_id` is refused
/// rather than silently read as the ambiguous form.
#[derive(Deserialize)]
struct ListParams {
    after: Option<i64>,
    after_id: Option<String>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
struct ResolveReportRequest {
    /// "resolved" or "dismissed".
    resolution: String,
}

/// What it takes to moderate one specific channel: the moderation bit and the
/// right to see the channel at all.
///
/// The two are inseparable here and were not always conjoined. `channels_where`
/// began life asking about `VIEW_CHANNEL` and was generalised to take the
/// permission as a parameter for this queue's sake, which quietly dropped the
/// view requirement rather than adding to it - its own doc comment still
/// records the generalisation. A caller holding deployment-wide
/// `MANAGE_MESSAGES` who is denied only `VIEW_CHANNEL` by a channel overwrite
/// therefore still satisfied `perms.contains(MANAGE_MESSAGES)` in that
/// channel, so its reports stayed in their queue - snapshot text and all -
/// from a channel the deployment had specifically hidden from them.
///
/// Every other channel-scoped gate in this crate already spells the pair out
/// (`voice.rs`'s `VIEW_CHANNEL | CONNECT`, `canvas_write.rs`'s
/// `VIEW_CHANNEL | USE_CANVAS`); this is the one place that had drifted, so it
/// is a named constant now rather than two call sites that must remember.
const MODERATES_CHANNEL: Permissions =
    Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_MESSAGES);

/// Lists one page of the open moderation queue, oldest first.
///
/// A report carries the reported content verbatim, so the queue is filtered
/// per channel rather than shown wholesale. `base_permissions` ignores channel
/// overwrites by construction, so a moderator explicitly denied
/// MANAGE_MESSAGES in one channel would otherwise still read every message
/// reported there. Reports with no channel are deployment-wide (a report about
/// a user rather than a message) and stay on the base check alone.
///
/// That exclusion is resolved once, into the set of channels the caller cannot
/// moderate, and applied in the `WHERE` rather than to the page after it is
/// read. Both orders answer the same, but filtering after a `LIMIT` makes a
/// short page ambiguous - a caller cannot tell it from the end of the queue -
/// so a moderator denied MANAGE_MESSAGES in one busy channel would silently
/// stop paging with reports they may read still ahead of them. It also drops
/// what the audit filed this route for: the per-report evaluation, several
/// indexed queries each, is now four queries for the whole page.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<ListParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ReportDto>>, ApiError> {
    require_manage_messages(&state, ctx.user_id).await?;
    let after = match (params.after, params.after_id.as_deref()) {
        (Some(created_at), Some(id)) => Some((created_at, parse_uuid(id)?)),
        (None, None) => None,
        _ => {
            return Err(ApiError::BadRequest(
                "after and after_id go together or not at all",
            ));
        }
    };
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);

    let report_channel_ids = state.store.open_report_channel_ids().await?;
    let hidden = hidden_channels(&state, ctx.user_id, &report_channel_ids).await?;
    let reports = state.store.list_open_reports(after, &hidden, limit).await?;

    let channel_ids: Vec<ChannelId> = reports.iter().filter_map(|r| r.channel_id).collect();
    let channel_permissions = state
        .store
        .permissions_in_channels(ctx.user_id, &channel_ids)
        .await?;

    let dtos = reports
        .into_iter()
        .map(|report| {
            let permissions = report.channel_id.map(|id| {
                channel_permissions
                    .get(&id)
                    .copied()
                    .unwrap_or(Permissions::NONE)
                    .bits()
            });
            ReportDto {
                channel_permissions: permissions,
                ..ReportDto::from(report)
            }
        })
        .collect();
    Ok(Json(dtos))
}

/// One page of the history feed. The cursor extends [`ListParams`]'s shape
/// across two source kinds: `after_kind` says which of [`HistoryCursor`]'s
/// variants `after`/`after_id` build, since a resolved report's id is a UUID
/// and an audit row's is an integer rowid, and neither parses as the other.
/// All three or none, the same all-or-nothing contract `ListParams` uses.
#[derive(Deserialize)]
struct HistoryListParams {
    after: Option<i64>,
    after_kind: Option<String>,
    after_id: Option<String>,
    limit: Option<i64>,
}

/// One entry in the moderation-history feed: a resolved report, carrying the
/// same fields [`ReportDto`] does plus its resolution, or a
/// `moderation_audit_log` row. `kind` is also the value `after_kind` expects
/// back, so a client can build its next page's cursor straight from the last
/// item on this one.
#[derive(Serialize)]
#[serde(tag = "kind")]
enum ModerationHistoryItemDto {
    #[serde(rename = "resolved_report")]
    ResolvedReport {
        id: String,
        reporter_id: Option<String>,
        subject_kind: String,
        subject_id: String,
        channel_id: Option<String>,
        reason: String,
        snapshot: Option<String>,
        subject_author_id: Option<String>,
        created_at: i64,
        resolved_at: i64,
        resolved_by: Option<String>,
        resolution: Option<String>,
    },
    #[serde(rename = "audit_log")]
    AuditLog {
        id: String,
        /// Null once the actor's account has been anonymized.
        actor_id: Option<String>,
        subject_id: String,
        action: String,
        reason: Option<String>,
        until: Option<i64>,
        created_at: i64,
    },
}

impl From<ModerationHistoryItem> for ModerationHistoryItemDto {
    fn from(item: ModerationHistoryItem) -> Self {
        match item {
            ModerationHistoryItem::ResolvedReport(report) => Self::ResolvedReport {
                id: report.id.to_string(),
                reporter_id: report.reporter_id.map(|id| id.to_string()),
                subject_kind: report.subject_kind,
                subject_id: report.subject_id.to_string(),
                channel_id: report.channel_id.map(|id| id.to_string()),
                reason: report.reason,
                snapshot: report.snapshot,
                subject_author_id: report.subject_author_id.map(|id| id.to_string()),
                created_at: report.created_at,
                resolved_at: report
                    .resolved_at
                    .expect("the history feed only ever carries resolved reports"),
                resolved_by: report.resolved_by.map(|id| id.to_string()),
                resolution: report.resolution,
            },
            ModerationHistoryItem::Audit(entry) => Self::AuditLog {
                id: entry.id.to_string(),
                actor_id: entry.actor_id.map(|id| id.to_string()),
                subject_id: entry.subject_id.to_string(),
                action: entry.action,
                reason: entry.reason,
                until: entry.until,
                created_at: entry.created_at,
            },
        }
    }
}

/// Lists one page of the moderation-history feed: resolved reports and
/// `moderation_audit_log` rows, merged and ordered newest first.
///
/// Gated on `MANAGE_MESSAGES` or `VIEW_MODERATION_HISTORY`, unlike [`list`];
/// see `docs/decisions/0028-bot-accounts.md`.
async fn history(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<HistoryListParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ModerationHistoryItemDto>>, ApiError> {
    let base = require_history_access(&state, ctx.user_id).await?;
    let after = match (
        params.after,
        params.after_kind.as_deref(),
        params.after_id.as_deref(),
    ) {
        (Some(event_time), Some(kind), Some(id)) => {
            Some(parse_history_cursor(event_time, kind, id)?)
        }
        (None, None, None) => None,
        _ => {
            return Err(ApiError::BadRequest(
                "after, after_kind and after_id go together or not at all",
            ));
        }
    };
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);

    let hidden = if base.contains(Permissions::VIEW_MODERATION_HISTORY) {
        Vec::new()
    } else {
        let report_channel_ids = state.store.report_channel_ids_including_resolved().await?;
        hidden_channels(&state, ctx.user_id, &report_channel_ids).await?
    };
    let items = state
        .store
        .moderation_history(after, &hidden, limit)
        .await?;

    Ok(Json(
        items
            .into_iter()
            .map(ModerationHistoryItemDto::from)
            .collect(),
    ))
}

/// The channels this caller may not read reports from: every live non-DM
/// channel [`crate::store::Store::list_channels`] returns that they cannot
/// moderate, plus every thread named in `report_channel_ids` that resolves to
/// one of those.
///
/// The complement rather than the allowed set, because the three kinds of report
/// that are *not* about a live non-DM channel - one with no channel, one about a
/// DM, one about a since-deleted channel - must stay visible on the caller's
/// deployment-wide bit alone, and none of them appears in `list_channels`. An
/// allowed-set predicate would hide all three.
///
/// A thread is the fourth kind absent from `list_channels`, but unlike the
/// other three it is not exempt - it resolves to a real, moderatable parent
/// channel (see [`crate::store::Store::channel_scopes_moderation`]), so a
/// report about one has to be excluded exactly when that parent is. The batch
/// above cannot see that resolution, since it never asks about a thread at
/// all; this loop asks only about the channels `report_channel_ids` names and
/// `list_channels` did not already answer for, reusing [`report_visible_in`]
/// rather than a second copy of its resolve-then-check logic.
///
/// `report_channel_ids` is the caller's choice of which reports' channels to
/// walk: [`list`] passes only open ones
/// ([`crate::store::Store::open_report_channel_ids`]), since that is all it
/// shows. [`history`] must pass every report's channel, open or resolved
/// ([`crate::store::Store::report_channel_ids_including_resolved`]) - a
/// resolved report still carries its content snapshot, and the open-only ids
/// stop naming a thread the instant its one report closes, which previously
/// let a resolved report from a thread under a hidden parent leak into the
/// history feed.
async fn hidden_channels(
    state: &AppState,
    user_id: UserId,
    report_channel_ids: &[ChannelId],
) -> Result<Vec<ChannelId>, ApiError> {
    let all_ids: std::collections::HashSet<ChannelId> = state
        .store
        .list_channels()
        .await?
        .into_iter()
        .map(|channel| channel.id)
        .collect();
    let moderatable: std::collections::HashSet<ChannelId> = state
        .store
        .channels_where(user_id, MODERATES_CHANNEL)
        .await?
        .into_iter()
        .map(|channel| channel.id)
        .collect();

    let mut hidden: Vec<ChannelId> = all_ids
        .iter()
        .copied()
        .filter(|id| !moderatable.contains(id))
        .collect();
    for channel_id in report_channel_ids {
        let channel_id = *channel_id;
        if !all_ids.contains(&channel_id) && !report_visible_in(state, user_id, channel_id).await {
            hidden.push(channel_id);
        }
    }
    Ok(hidden)
}

/// Closes a report as resolved or dismissed. The claim is a conditional
/// `UPDATE` in the store, so two moderators racing the same report cannot
/// both win it; whichever loses sees the report as already gone.
///
/// Gated per channel exactly as [`list`] is. Without that, a moderator denied
/// MANAGE_MESSAGES in one channel could not read its reports but could still
/// dismiss them, quietly emptying the queue for the very channel they were
/// deliberately excluded from. A report they may not act on is reported as
/// missing rather than forbidden, so the endpoint does not confirm one exists.
async fn resolve(
    Authed(ctx): Authed,
    parts: Parts,
    Path(report_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<ResolveReportRequest>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_messages(&state, ctx.user_id).await?;
    let report_id = parse_uuid(&report_id)?;

    let resolution = match req.resolution.as_str() {
        "resolved" | "dismissed" => req.resolution.as_str(),
        _ => {
            return Err(ApiError::BadRequest(
                "resolution must be resolved or dismissed",
            ));
        }
    };

    let Some(channel_id) = state.store.open_report_channel(report_id).await? else {
        return Err(missing_or_closed(&state, report_id).await?);
    };
    if let Some(channel_id) = channel_id
        && !report_visible_in(&state, ctx.user_id, channel_id).await
    {
        return Err(ApiError::NotFound("report not found"));
    }

    let closed = state
        .store
        .resolve_report(report_id, ctx.user_id, resolution)
        .await?;
    if !closed {
        return Err(missing_or_closed(&state, report_id).await?);
    }
    // No content rides along; see `Event::ReportsChanged`'s own doc.
    state.hub.publish(Event::ReportsChanged);
    Ok(StatusCode::NO_CONTENT)
}

/// The bar for [`history`]: either bit clears it.
async fn require_history_access(
    state: &AppState,
    user_id: UserId,
) -> Result<Permissions, ApiError> {
    let base = state.store.base_permissions(user_id).await?;
    if !base.intersects(Permissions::MANAGE_MESSAGES.union(Permissions::VIEW_MODERATION_HISTORY)) {
        return Err(ApiError::Forbidden);
    }
    Ok(base)
}

/// Whether a base-level moderator may see or act on a report in this channel.
///
/// The caller has already passed the deployment-wide `MANAGE_MESSAGES` check.
/// A report in a live text or voice channel is further restricted to that
/// channel's own moderators, so a moderator excluded from one channel cannot
/// reach into it. A report in a DM or a since-deleted channel has no such
/// moderators to defer to, so it stays with the deployment moderators rather
/// than falling into a per-channel check that grants it to nobody. That hole
/// was accepting DM harassment reports and hiding them forever.
async fn report_visible_in(state: &AppState, user_id: UserId, channel_id: ChannelId) -> bool {
    match state.store.channel_scopes_moderation(channel_id).await {
        Ok(false) => true,
        Ok(true) => state
            .store
            .has_permission(user_id, channel_id, MODERATES_CHANNEL)
            .await
            .unwrap_or(false),
        Err(_) => false,
    }
}
