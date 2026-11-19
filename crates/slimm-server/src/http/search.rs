// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Full-text search over messages through FTS5, with `from:`, `in:`, `has:`,
//! `mentions:`, `pinned:` and date operators, for one channel or every
//! channel the caller can view (grammar: docs/search.md).
//! [`resolve_scope`] is the one place `in:` is permission-filtered, and the
//! channel restriction is SQL the query text can never reach; see
//! docs/internals.md.

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::Deserialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, Query};
use super::message_enrich::with_reactions;
use super::messages::{MessageDto, parse_uuid};
use super::search_dates::parse_date_start;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::store::{HasKind, MentionedUser, MessageSearchFilters, SearchError};

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
    /// The id of the last message on the previous page; see
    /// [`crate::store::MessageSearchFilters::before_id`].
    before_id: Option<String>,
    limit: Option<i64>,
    /// `from:username`, compared case-insensitively - see
    /// [`crate::store::MessageSearchFilters::author_username`].
    from: Option<String>,
    /// `in:channel-name`, a distinct channel to search instead of the one
    /// named in the path. Named `in` on the wire to match the operator
    /// verbatim; renamed here only because `in` is a Rust keyword.
    #[serde(rename = "in")]
    in_channel: Option<String>,
    /// One or more [`HasKind`] values, comma-separated (`has=image,link`).
    has: Option<String>,
    /// `mentions:username`: messages that directly mention this account.
    mentions: Option<String>,
    /// `pinned:true` or `pinned:false`.
    pinned: Option<bool>,
    /// `after:YYYY-MM-DD`. Named `after_date` on the wire so it cannot be
    /// confused with a future `after` seq cursor the way `before` already
    /// exists for pagination.
    after_date: Option<String>,
    /// `before:YYYY-MM-DD`. Named `before_date` on the wire for the same
    /// reason, and because `before` already means "seq cursor" here.
    before_date: Option<String>,
    /// Also search the live threads of the channels in scope. Opt-in because a
    /// client from before thread hits opens one as if the thread were a channel.
    include_threads: Option<bool>,
}

/// The channels a search covers, and whether their live threads come along.
struct SearchScope<'a> {
    channels: &'a [ChannelId],
    with_threads: bool,
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
    let Some(filters) = with_mentioned(&state, filters, params.mentions.as_deref()).await? else {
        return Ok(Json(Vec::new()));
    };

    run_search(
        &state,
        ctx.user_id,
        SearchScope {
            channels: &channel_ids,
            with_threads: params.include_threads.unwrap_or(false),
        },
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
    let Some(filters) = with_mentioned(&state, filters, params.mentions.as_deref()).await? else {
        return Ok(Json(Vec::new()));
    };

    run_search(
        &state,
        ctx.user_id,
        SearchScope {
            channels: &channel_ids,
            with_threads: params.include_threads.unwrap_or(false),
        },
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
    let has = parse_has(params.has.as_deref())?;
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
        && has.is_empty()
        && params.mentions.is_none()
        && params.pinned.is_none()
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
        has,
        mentions: None,
        pinned: params.pinned,
        after_ms,
        before_ms,
        before_id: params
            .before_id
            .as_deref()
            .map(|raw| parse_uuid(raw).map(MessageId))
            .transpose()?,
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
/// resolved: run the FTS5 query over the scope's channels (and their live
/// threads when asked), then enrich with reactions like plain history does.
async fn run_search(
    state: &AppState,
    user_id: UserId,
    scope: SearchScope<'_>,
    query: Option<&str>,
    filters: &MessageSearchFilters,
    before: Option<i64>,
    limit: i64,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let fts = match query {
        Some(q) => match state.store.fts_query_for(q).await {
            Ok(Some(fts)) => Some(fts),
            Ok(None) => return Ok(Json(Vec::new())),
            Err(SearchError::Internal(e)) => return Err(e.into()),
            Err(_) => return Err(ApiError::BadRequest("that search query is not valid")),
        },
        None => None,
    };
    let query = fts.as_ref();
    let threads = match scope.with_threads {
        true => state.store.live_threads_of(scope.channels).await?,
        false => Default::default(),
    };
    let mut channels = scope.channels.to_vec();
    channels.extend(threads.keys().copied());
    let messages = match state
        .store
        .search_messages_prepared(&channels, query, filters, before, limit)
        .await
    {
        Ok(rows) => rows,
        Err(SearchError::InvalidQuery) => {
            return Err(ApiError::BadRequest("that search query is not valid"));
        }
        Err(SearchError::UnknownCursor) => {
            return Err(ApiError::BadRequest("before_id names no message"));
        }
        Err(SearchError::Internal(e)) => return Err(e.into()),
    };

    let ids: Vec<MessageId> = messages.iter().map(|m| m.id).collect();
    let thread_parents: Vec<Option<String>> = messages
        .iter()
        .map(|m| threads.get(&m.channel_id).map(ToString::to_string))
        .collect();
    let mut dtos = with_reactions(state, user_id, messages).await?;
    if let Some(q) = query {
        let mut matched = state
            .store
            .attachments_matching_text(&ids, q.as_str())
            .await?;
        for (id, dto) in ids.iter().zip(dtos.iter_mut()) {
            dto.matched_attachment_id = matched.remove(id);
        }
    }
    for (dto, parent) in dtos.iter_mut().zip(thread_parents) {
        dto.thread_parent_channel_id = parent;
    }
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

/// Every [`HasKind`] in one comma-separated `has` param, each at most once.
/// An unrecognised value is a 400 rather than a silent no-op, so a typo does
/// not read as "no matches" the way a wrongly-spelled `in:` channel does -
/// there is no oracle-safety reason to hide the difference here, since a
/// `has:` value is never itself a secret to protect.
fn parse_has(has: Option<&str>) -> Result<Vec<HasKind>, ApiError> {
    let Some(has) = has else {
        return Ok(Vec::new());
    };
    let mut kinds = Vec::new();
    for value in has.split(',') {
        let kind = HasKind::parse(value.trim()).ok_or(ApiError::BadRequest(
            "has must name a kind of content the API lists",
        ))?;
        if !kinds.contains(&kind) {
            kinds.push(kind);
        }
    }
    Ok(kinds)
}

/// `filters` with `mentions:` resolved to its live account, or `None` when the
/// name matches nobody: like `from:`, an unknown person answers empty, never an error.
async fn with_mentioned(
    state: &AppState,
    mut filters: MessageSearchFilters,
    username: Option<&str>,
) -> Result<Option<MessageSearchFilters>, ApiError> {
    let Some(username) = username else {
        return Ok(Some(filters));
    };
    let Some(id) = state.store.live_user_id_by_username(username).await? else {
        return Ok(None);
    };
    filters.mentions = Some(MentionedUser {
        id,
        username: username.to_owned(),
    });
    Ok(Some(filters))
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
    fn has_parses_each_kind_once_in_the_order_given() {
        assert!(ok(parse_has(None)).is_empty());
        assert_eq!(ok(parse_has(Some("link"))), [HasKind::Link]);
        assert_eq!(
            ok(parse_has(Some("image, poll,image"))),
            [HasKind::Image, HasKind::Poll]
        );
    }

    #[test]
    fn has_rejects_an_unknown_value() {
        assert!(parse_has(Some("gif")).is_err());
        assert!(parse_has(Some("attachment,gif")).is_err());
    }
}
