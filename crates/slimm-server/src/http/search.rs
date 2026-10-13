// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Full-text search over messages, backed by the FTS5 index kept current by
//! the triggers in migration 0002, plus a Slack-style operator layer over
//! it: `from:`, `in:`, `has:`, `before:`/`after:`.
//!
//! Two routes share every bit of this file beyond their own permission
//! scoping: `GET /channels/{channelId}/messages/search` (the channel
//! header's search panel) searches one channel, named in the path or by
//! `in:`, and requires `VIEW_CHANNEL` on the path channel up front; `GET
//! /search/messages` (the command palette's cross-channel scope) has no path
//! channel to check and instead searches every channel
//! [`crate::store::Store::visible_channels`] says the caller can view, or the
//! subset of those named by `in:` when given. Neither ever reaches a channel
//! the caller cannot view: [`resolve_scope`] is the one place `in:` is
//! resolved and permission-filtered for both, and the cross-channel
//! route's default scope is `visible_channels` itself, which only ever
//! returns channels `VIEW_CHANNEL` already grants. `visible_channels` also
//! excludes DMs and threads (see its own doc comment), so cross-channel
//! search never reaches a DM the caller was not searching directly.
//!
//! `q` reaches FTS5 close to as-is, so a caller may use its mini query
//! language (`AND`/`OR`/`NOT`, `"phrase"`, a trailing `*` prefix). That is
//! safe against leaking another channel: the index has exactly one column
//! (`content`), so a query string has no other column to pivot to, and the
//! channel restriction is an ordinary SQL predicate the query text can never
//! reach, never part of the `MATCH` expression itself. See
//! [`crate::store::Store::search_messages`] for the rest of that reasoning
//! and for how a malformed query surfaces as [`SearchError::InvalidQuery`]
//! rather than a 500: SQLite only validates FTS5 syntax once the statement
//! runs.
//!
//! The operators are parsed client-side (`message_search_query.dart`), which
//! is why this file only ever sees them as already-split query parameters -
//! `q` never carries `from:nick` as literal text a caller could exploit to
//! widen a channel restriction the way `q` itself cannot.
//!
//! Channel and member search need no route here at all: both are already
//! answered from data the client already holds permission-correctly. `GET
//! /channels` only ever lists what [`crate::store::Store::visible_channels`]
//! grants, so the client's local channel list is never wider than that; the
//! member list (`GET /members`) is deployment-wide by design (see
//! `http::users`'s own doc comment), not scoped to a channel, so there is no
//! per-channel visibility question to get wrong there. The command palette
//! (`command_palette_items.dart`) filters both lists by name locally.

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, Query};
use super::message_enrich::with_reactions;
use super::messages::{MessageDto, parse_uuid};
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::{MessageSearchFilters, SearchError};

/// Longest a search query may be.
use crate::limits::MAX_QUERY_CHARS;
/// Default and maximum page sizes. The same numbers `http::messages` uses
/// today, deliberately not imported from it: a page size is a per-route
/// decision each module is entitled to make, and coupling the two would mean
/// search could not be retuned without moving history with it. Raised twice
/// as duplication (2026-07-30, 2026-09-20) and rejected both times; see
/// `docs/research/audit-2026-07-30/rejected.md`. This comment says they
/// happen to agree, not that anything holds them together.
const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 100;

/// The search routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/messages/search", get(search))
        .route("/search/messages", get(search_all))
}

#[derive(Deserialize)]
struct SearchParams {
    q: Option<String>,
    before: Option<i64>,
    limit: Option<i64>,
    /// `from:username`, compared exactly - see
    /// [`crate::store::MessageSearchFilters::author_username`].
    from: Option<String>,
    /// `in:channel-name`, a distinct channel to search instead of the one
    /// named in the path. Named `in` on the wire to match the operator
    /// verbatim; renamed here only because `in` is a Rust keyword.
    #[serde(rename = "in")]
    in_channel: Option<String>,
    /// `has:attachment` and/or `has:link`, comma-separated when both are
    /// given (`has=attachment,link`).
    has: Option<String>,
    /// `after:YYYY-MM-DD`. Named `after_date` on the wire so it cannot be
    /// confused with a future `after` seq cursor the way `before` already
    /// exists for pagination.
    after_date: Option<String>,
    /// `before:YYYY-MM-DD`. Named `before_date` on the wire for the same
    /// reason, and because `before` already means "seq cursor" here.
    before_date: Option<String>,
}

/// Full-text search within one channel, or within an `in:`-named one.
///
/// A nonexistent channel grants no permissions, so the path channel refuses
/// both "you cannot search here" and "no such channel" identically, exactly
/// like listing. `in:` gets the same treatment one level in: a channel name
/// that resolves to nothing, or to only channels the caller cannot view,
/// answers with an empty result - never a 403 or 404 - so it cannot become a
/// second way to learn a hidden channel exists. See
/// `mask_unless_viewable` in `permissions.rs` for the same shape applied to
/// a permission bitmask instead of a result list.
///
/// The path channel's own `VIEW_CHANNEL` is still checked first,
/// unconditionally: a caller who cannot view the channel they are searching
/// *from* is refused before `in:` is ever looked at, even if `in:` names a
/// channel they could otherwise read.
async fn search(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    Query(params): Query<SearchParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    // A missing channel and a denied one answer alike; see the note above.
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    let (query, filters, limit) = parse_request(&params)?;
    let scope = resolve_scope(
        &state,
        ctx.user_id,
        params.in_channel.as_deref(),
        vec![channel_id],
    )
    .await?;
    // No such `in:` channel, or none viewable - both answer empty; see this fn's own doc.
    let Some(channel_ids) = scope else {
        return Ok(Json(Vec::new()));
    };

    run_search(
        &state,
        ctx.user_id,
        &channel_ids,
        query,
        &filters,
        params.before,
        limit,
    )
    .await
}

/// Full-text search across every channel the caller can view, or within an
/// `in:`-named subset of them.
///
/// Unlike [`search`], there is no path channel to gate on: the scope itself
/// *is* the permission check. With no `in:`, the scope is
/// [`crate::store::Store::visible_channels`], which by construction never
/// contains a channel the caller cannot view. With `in:`, it goes through
/// the same [`resolve_scope`] helper [`search`] uses for its own `in:`, so a
/// name that resolves to nothing viewable answers empty rather than a 403 or
/// 404, for the same oracle-safety reason documented there.
async fn search_all(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<SearchParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let (query, filters, limit) = parse_request(&params)?;
    let default = state
        .store
        .visible_channels(ctx.user_id)
        .await?
        .into_iter()
        .map(|c| c.id)
        .collect();
    let scope = resolve_scope(&state, ctx.user_id, params.in_channel.as_deref(), default).await?;
    let Some(channel_ids) = scope else {
        return Ok(Json(Vec::new()));
    };

    run_search(
        &state,
        ctx.user_id,
        &channel_ids,
        query,
        &filters,
        params.before,
        limit,
    )
    .await
}

/// Parses and validates the parts of a search request both routes share: the
/// optional free-text query, the Slack-style content filters, and the
/// clamped page size. Refuses a request naming neither a query nor any
/// filter (including `in:`, itself not a content filter but still a reason
/// to run), the one validation rule that predates either route having an
/// `in:` scope at all.
fn parse_request(
    params: &SearchParams,
) -> Result<(Option<&str>, MessageSearchFilters, i64), ApiError> {
    let query = validate_query(params.q.as_deref())?;
    let (has_attachment, has_link) = parse_has(params.has.as_deref())?;
    let after_ms = params
        .after_date
        .as_deref()
        .map(parse_date_start)
        .transpose()?;
    let before_ms = params
        .before_date
        .as_deref()
        .map(parse_date_start)
        .transpose()?;

    if query.is_none()
        && params.from.is_none()
        && params.in_channel.is_none()
        && !has_attachment
        && !has_link
        && after_ms.is_none()
        && before_ms.is_none()
    {
        return Err(ApiError::BadRequest(
            "search needs a query or at least one filter",
        ));
    }

    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let filters = MessageSearchFilters {
        author_username: params.from.clone(),
        has_attachment,
        has_link,
        after_ms,
        before_ms,
    };
    Ok((query, filters, limit))
}

/// Resolves a request's channel scope: `in_channel_name`, when given, names a
/// channel to search instead of `default` and is resolved the same way for
/// both routes - every live channel with that name (never unique, see
/// [`crate::store::Store::search_channel_ids_by_name`]), narrowed to the
/// ones the caller holds `VIEW_CHANNEL` in with one batched permission check
/// rather than one per candidate. `None` means nothing came out the other
/// end viewable - no such name, or a real one entirely hidden from this
/// caller - which both routes turn into an empty result rather than a 403 or
/// 404, so `in:` can never be used to learn a hidden channel exists.
///
/// With no `in:`, `default` is used as-is, empty included: [`search_all`]
/// passes its own already-permission-scoped list here, so an empty one
/// (nothing visible at all) belongs in the same empty-result branch as a
/// hidden `in:` name, not a separate check.
async fn resolve_scope(
    state: &AppState,
    user_id: UserId,
    in_channel_name: Option<&str>,
    default: Vec<ChannelId>,
) -> Result<Option<Vec<ChannelId>>, ApiError> {
    let Some(name) = in_channel_name else {
        return Ok(if default.is_empty() {
            None
        } else {
            Some(default)
        });
    };
    let candidates = state.store.search_channel_ids_by_name(name).await?;
    let permissions = state
        .store
        .permissions_in_channels(user_id, &candidates)
        .await?;
    let viewable: Vec<ChannelId> = candidates
        .into_iter()
        .filter(|candidate| {
            permissions
                .get(candidate)
                .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
        })
        .collect();
    Ok(if viewable.is_empty() {
        None
    } else {
        Some(viewable)
    })
}

/// The shared tail both routes run once their channel scope and filters are
/// resolved: run the FTS5 query over `channel_ids`, then enrich with
/// reactions exactly like plain message history does.
async fn run_search(
    state: &AppState,
    user_id: UserId,
    channel_ids: &[ChannelId],
    query: Option<&str>,
    filters: &MessageSearchFilters,
    before: Option<i64>,
    limit: i64,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let messages = match state
        .store
        .search_messages(channel_ids, query, filters, before, limit)
        .await
    {
        Ok(rows) => rows,
        Err(SearchError::InvalidQuery) => {
            return Err(ApiError::BadRequest("that search query is not valid"));
        }
        Err(SearchError::Internal(e)) => return Err(e.into()),
    };

    let dtos = with_reactions(state, user_id, messages).await?;
    Ok(Json(dtos))
}

/// `None` when `q` was never sent at all (an advanced search made entirely of
/// operators); `Some` blank or over-length is still refused, unchanged from
/// before this file supported operators.
fn validate_query(q: Option<&str>) -> Result<Option<&str>, ApiError> {
    let Some(q) = q else {
        return Ok(None);
    };
    let trimmed = q.trim();
    if trimmed.is_empty() {
        return Err(ApiError::BadRequest("search query must not be empty"));
    }
    if trimmed.chars().count() > MAX_QUERY_CHARS {
        return Err(ApiError::BadRequest("search query is too long"));
    }
    Ok(Some(trimmed))
}

/// `has:attachment` and/or `has:link`, comma-separated in one `has` param.
/// An unrecognised value is a 400 rather than a silent no-op, so a typo does
/// not read as "no matches" the way a wrongly-spelled `in:` channel does -
/// there is no oracle-safety reason to hide the difference here, since a
/// `has:` value is never itself a secret to protect.
fn parse_has(has: Option<&str>) -> Result<(bool, bool), ApiError> {
    let Some(has) = has else {
        return Ok((false, false));
    };
    let mut attachment = false;
    let mut link = false;
    for value in has.split(',') {
        match value.trim() {
            "attachment" => attachment = true,
            "link" => link = true,
            other => {
                return Err(ApiError::BadRequest(match other {
                    "" => "has must name attachment or link",
                    _ => "has must be attachment or link",
                }));
            }
        }
    }
    Ok((attachment, link))
}

/// Parses a `YYYY-MM-DD` calendar date into the epoch millisecond at its
/// midnight UTC start, so `before:`/`after:` compare against `created_at`
/// with no timezone to resolve. Byte-indexed rather than `str`-sliced: a
/// length check alone does not rule out a multi-byte character landing where
/// a slice boundary would fall, which `&s[0..4]`-style slicing can panic on.
fn parse_date_start(s: &str) -> Result<i64, ApiError> {
    const BAD: ApiError = ApiError::BadRequest("date must be YYYY-MM-DD");
    let bytes = s.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return Err(BAD);
    }
    let digit = |b: u8| -> Result<i64, ApiError> {
        if b.is_ascii_digit() {
            Ok((b - b'0') as i64)
        } else {
            Err(BAD)
        }
    };
    let year =
        digit(bytes[0])? * 1000 + digit(bytes[1])? * 100 + digit(bytes[2])? * 10 + digit(bytes[3])?;
    let month = (digit(bytes[5])? * 10 + digit(bytes[6])?) as u32;
    let day = (digit(bytes[8])? * 10 + digit(bytes[9])?) as u32;
    if !(1..=12).contains(&month) {
        return Err(BAD);
    }
    let dim = days_in_month(year, month);
    if day < 1 || day > dim {
        return Err(BAD);
    }
    Ok(days_from_civil(year, month, day) * 86_400_000)
}

fn is_leap_year(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if is_leap_year(y) {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}

/// Howard Hinnant's `days_from_civil`: the standard, well-tested closed-form
/// conversion from a proleptic Gregorian calendar date to a day count
/// relative to the Unix epoch (1970-01-01 = 0). Chosen over the `jiff`
/// dependency already in this workspace because nothing else here uses it
/// yet, and a closed-form arithmetic conversion this small is easier to
/// trust by reading than by taking on an unfamiliar API for one call site.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `ApiError` carries no `Debug` impl (it is not one of this crate's
    /// public-facing types), so a bare `.unwrap()` on a `Result<_, ApiError>`
    /// will not compile; this is the Debug-free equivalent.
    fn ok<T>(r: Result<T, ApiError>) -> T {
        match r {
            Ok(v) => v,
            Err(_) => panic!("expected Ok"),
        }
    }

    #[test]
    fn epoch_day_is_zero() {
        assert_eq!(ok(parse_date_start("1970-01-01")), 0);
    }

    #[test]
    fn a_known_date_matches_a_reference_conversion() {
        assert_eq!(ok(parse_date_start("2024-01-01")), 1_704_067_200_000);
        assert_eq!(ok(parse_date_start("2024-02-29")), 1_709_164_800_000);
        assert_eq!(ok(parse_date_start("2000-03-01")), 951_868_800_000);
        assert_eq!(ok(parse_date_start("1999-12-31")), 946_598_400_000);
    }

    #[test]
    fn a_non_leap_year_february_stops_at_28() {
        assert!(parse_date_start("2023-02-29").is_err());
        assert!(parse_date_start("2023-02-28").is_ok());
    }

    #[test]
    fn month_and_day_are_range_checked() {
        assert!(parse_date_start("2024-13-01").is_err());
        assert!(parse_date_start("2024-00-01").is_err());
        assert!(parse_date_start("2024-04-31").is_err());
        assert!(parse_date_start("2024-04-00").is_err());
    }

    #[test]
    fn malformed_shapes_are_rejected_rather_than_panicking() {
        assert!(parse_date_start("2024/01/01").is_err());
        assert!(parse_date_start("2024-1-1").is_err());
        assert!(parse_date_start("not-a-date").is_err());
        assert!(parse_date_start("").is_err());
        // A 2-byte `é` keeping the total byte length at 10 must not panic on slicing.
        assert!(parse_date_start("20é-01-01").is_err());
    }

    #[test]
    fn has_parses_either_value_both_or_neither() {
        assert_eq!(ok(parse_has(None)), (false, false));
        assert_eq!(ok(parse_has(Some("attachment"))), (true, false));
        assert_eq!(ok(parse_has(Some("link"))), (false, true));
        assert_eq!(ok(parse_has(Some("attachment,link"))), (true, true));
    }

    #[test]
    fn has_rejects_an_unknown_value() {
        assert!(parse_has(Some("gif")).is_err());
        assert!(parse_has(Some("attachment,gif")).is_err());
    }
}
