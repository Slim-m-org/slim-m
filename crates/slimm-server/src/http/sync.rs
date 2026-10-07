// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Read-state and bundled catch-up routes.
//!
//! `PUT /channels/{id}/read` advances the caller's last-read marker and returns
//! the fresh unread count; `GET` reads it back. `POST /sync` is the reconnect
//! path: a client sends its per-scope cursors in one request (so a reconnect
//! storm is one request per user, not one per channel) and gets back the
//! messages after each cursor, authorized per scope.
//!
//! The response is bounded three ways: each scope is capped, the whole response
//! is capped, and a scope whose cursor is very far behind returns `reset` rather
//! than a long backlog, telling the client to discard local state and re-fetch
//! that channel fresh over REST.

use std::collections::HashMap;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::{get, post, put};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, WRITE};
use super::message_enrich::with_reactions;
use super::messages::{MessageDto, parse_uuid};
use super::sync_ops::{MessageOpDto, SYNC_RESPONSE_BYTES, ops_for_scope};
use crate::ids::ChannelId;
use crate::permissions::Permissions;

/// Sync bodies are a list of small cursors; cap the body accordingly.
const SYNC_BODY_LIMIT: usize = 64 * 1024;
/// Most scopes a single sync may ask about.
const MAX_SCOPES: usize = 200;
/// Most messages returned for one scope.
const PER_SCOPE_LIMIT: i64 = 100;
/// Most messages returned across the whole response.
const AGGREGATE_LIMIT: i64 = 500;
/// A cursor further behind than this returns `reset` instead of a backlog.
const SNAPSHOT_GAP: i64 = 1000;

/// The read-state and sync routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels/{channel_id}/read", get(get_read).put(put_read))
        .route("/channels/{channel_id}/unread", put(put_unread))
        .route("/sync", post(sync))
        .layer(DefaultBodyLimit::max(SYNC_BODY_LIMIT))
}

// --- Wire types ---

#[derive(Deserialize)]
struct MarkReadRequest {
    seq: i64,
}

#[derive(Serialize)]
pub(super) struct ReadStateDto {
    pub(super) last_read_seq: i64,
    pub(super) unread: i64,
    /// Whether the reader asked to see this channel as unread even though
    /// they have read it. Separate from `unread` because they are different
    /// facts: `unread` counts messages, this records an intention.
    pub(super) manually_unread: bool,
}

#[derive(Deserialize)]
struct SyncRequest {
    scopes: Vec<ScopeCursor>,
}

#[derive(Deserialize)]
struct ScopeCursor {
    channel_id: String,
    after_seq: i64,
    /// The message-op cursor, absent when the client holds none.
    ///
    /// Absent is what every older client sends and what a newer one sends
    /// before it has adopted a head. Both take the same branch, and a scope
    /// that carries none is never told to reset from an op gap.
    #[serde(default)]
    after_op_seq: Option<i64>,
}

#[derive(Serialize)]
struct SyncResponse {
    scopes: Vec<ScopeDelta>,
}

#[derive(Serialize)]
struct ScopeDelta {
    channel_id: String,
    messages: Vec<MessageDto>,
    /// More messages remain past what this response carried.
    has_more: bool,
    /// Either cursor was too far behind; discard local state and re-fetch.
    ///
    /// One flag rather than two, because the client's recovery is identical
    /// whichever cursor could not be answered. It is only ever set from an op
    /// gap for a scope whose request carried an op cursor.
    reset: bool,
    /// Empty whenever the request carried no op cursor, and empty when there
    /// is genuinely nothing.
    ops: Vec<MessageOpDto>,
    /// The head of this channel's op stream. Always present on this server,
    /// which is how a new client tells it from one that has no op stream.
    op_latest_seq: i64,
    ops_has_more: bool,
}

// --- Handlers ---

async fn get_read(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

async fn put_read(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<MarkReadRequest>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if req.seq < 0 {
        return Err(ApiError::BadRequest("seq must not be negative"));
    }
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    super::read_sync::advance_and_announce(&state, ctx.user_id, channel_id, req.seq).await?;
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

/// Marks a channel unread: the note-to-self every comparable app offers.
///
/// A write rather than a read, and rate limited as one, because it stores an
/// intention. It deliberately does not move `last_read_seq`, which is
/// monotonic so that a late or out-of-order mark can never un-read a channel;
/// see [`crate::store::Store::mark_unread`].
async fn put_unread(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ReadStateDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    if let Some(last_read_seq) = state.store.mark_unread(ctx.user_id, channel_id).await? {
        state.hub.publish(crate::hub::Event::ReadStateChanged {
            user_id: ctx.user_id,
            channel_id,
            last_read_seq,
            manually_unread: true,
        });
    }
    Ok(Json(read_state_for(&state, ctx.user_id, channel_id).await?))
}

/// The three reads every read-state answer needs, in one place so the two
/// handlers that return one cannot drift apart.
async fn read_state_for(
    state: &AppState,
    user_id: crate::ids::UserId,
    channel_id: ChannelId,
) -> Result<ReadStateDto, ApiError> {
    Ok(ReadStateDto {
        last_read_seq: state.store.last_read_seq(user_id, channel_id).await?,
        unread: state.store.unread_count(user_id, channel_id).await?,
        manually_unread: state.store.manually_unread(user_id, channel_id).await?,
    })
}

/// Catches a client up across several channels at once, under a per-scope, an
/// aggregate and a snapshot-gap cap.
///
/// Deltas go through `with_reactions`, exactly as list and search do, rather
/// than a bare `MessageDto::from`. The bare conversion leaves `reactions`
/// empty, so a message that arrived by catch-up came back with no reactions at
/// all while the same message fetched by list carried them, and a client that
/// trusts its local store showed the difference.
async fn sync(
    AuthedLimited(ctx): AuthedLimited<WRITE>,
    State(state): State<AppState>,
    Json(req): Json<SyncRequest>,
) -> Result<Json<SyncResponse>, ApiError> {
    if req.scopes.len() > MAX_SCOPES {
        return Err(ApiError::BadRequest("too many scopes"));
    }

    // Collapse duplicate channels so a request padded with repeats cannot
    // multiply the per-scope database work.
    let cursors = dedupe_scopes(req.scopes);

    // Parse every id up front, so a malformed one still fails the whole request as it did when parsing was inside the loop.
    let parsed: Vec<(ScopeCursor, ChannelId)> = cursors
        .into_iter()
        .map(|cursor| {
            let channel_id = ChannelId(parse_uuid(&cursor.channel_id)?);
            Ok::<_, ApiError>((cursor, channel_id))
        })
        .collect::<Result<_, _>>()?;

    // One batched permission fetch, not four-to-five queries per channel in the loop; permissions_in_channels resolves up to MAX_SCOPES channels against one roles/timeout load, as the rail, report and saved-messages paths already do.
    let channel_ids: Vec<ChannelId> = parsed.iter().map(|(_, id)| *id).collect();
    let permissions = state
        .store
        .permissions_in_channels(ctx.user_id, &channel_ids)
        .await?;

    let mut scopes = Vec::new();
    let mut budget = AGGREGATE_LIMIT;
    let mut bytes = SYNC_RESPONSE_BYTES;
    for (cursor, channel_id) in parsed {
        // Silently skip scopes the caller cannot view, so sync never confirms a
        // hidden channel exists.
        if !permissions
            .get(&channel_id)
            .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
        {
            continue;
        }

        // Read after the permission check, never before it.
        let ops = ops_for_scope(&state, channel_id, cursor.after_op_seq, &mut bytes).await?;

        let latest = state.store.latest_message_seq(channel_id).await?;
        let (messages, has_more, message_reset) = if cursor.after_seq > latest {
            // A cursor past the head is what a Litestream restore produces; see `sync_ops`.
            (Vec::new(), false, true)
        } else if cursor.after_seq == latest {
            (Vec::new(), false, false)
        } else if latest.saturating_sub(cursor.after_seq) > SNAPSHOT_GAP {
            (Vec::new(), true, true)
        } else {
            let limit = PER_SCOPE_LIMIT.min(budget);
            if limit <= 0 {
                // The aggregate budget is spent; report more remains here.
                (Vec::new(), true, false)
            } else {
                let mut rows = state
                    .store
                    .messages_since(channel_id, cursor.after_seq, limit + 1)
                    .await?;
                let has_more = rows.len() as i64 > limit;
                rows.truncate(limit as usize);
                // `with_reactions`, never a bare `MessageDto::from`; see the
                // note on this function.
                let mut dtos = with_reactions(&state, ctx.user_id, rows).await?;
                let trimmed = trim_messages_to_budget(&mut dtos, &mut bytes);
                budget -= dtos.len() as i64;
                (dtos, has_more || trimmed, false)
            }
        };

        scopes.push(ScopeDelta {
            channel_id: cursor.channel_id,
            messages,
            has_more,
            reset: message_reset || ops.reset,
            ops: ops.ops,
            op_latest_seq: ops.op_latest_seq,
            ops_has_more: ops.ops_has_more,
        });
    }

    Ok(Json(SyncResponse { scopes }))
}

/// Drops messages from the back until the page fits the shared byte budget,
/// answering whether it cut any - the message half of what
/// `sync_ops::trim_to_budget` does for ops, so the budget binds both halves
/// rather than only being subtracted after the fact.
///
/// The first row is always admitted however little budget is left, for the
/// same reason the op half admits its first: one message longer than the
/// whole budget would otherwise stall the cursor forever. A page cut here
/// reports `has_more`, so the client asks again from the last row it kept.
fn trim_messages_to_budget(dtos: &mut Vec<MessageDto>, budget: &mut usize) -> bool {
    let mut kept = 0usize;
    for (i, dto) in dtos.iter().enumerate() {
        let cost = dto.wire_cost();
        if i > 0 && cost > *budget {
            break;
        }
        *budget = budget.saturating_sub(cost);
        kept = i + 1;
    }
    let trimmed = kept < dtos.len();
    dtos.truncate(kept);
    trimmed
}

/// Collapses repeated channels, keeping the cursor that asks for the most (the
/// smallest `after_seq`), so the request cannot be padded to inflate work.
///
/// The op cursor reconciles the same way: two `Some`s keep the smaller, and a
/// `Some` beats an absent one, since delivering ops is asking for more than
/// adopting a head. This used to silently keep whichever duplicate came
/// first, which for a `None`-then-`Some` pair dropped the op cursor
/// entirely - latent, since the real client never sends duplicates, but a
/// dedupe that quietly discards half a cursor is wrong on its own terms.
fn dedupe_scopes(scopes: Vec<ScopeCursor>) -> Vec<ScopeCursor> {
    let mut deduped: Vec<ScopeCursor> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for cursor in scopes {
        match index.get(&cursor.channel_id) {
            Some(&at) => {
                deduped[at].after_seq = deduped[at].after_seq.min(cursor.after_seq);
                deduped[at].after_op_seq = match (deduped[at].after_op_seq, cursor.after_op_seq) {
                    (Some(kept), Some(dup)) => Some(kept.min(dup)),
                    (kept, dup) => kept.or(dup),
                };
            }
            None => {
                index.insert(cursor.channel_id.clone(), deduped.len());
                deduped.push(cursor);
            }
        }
    }
    deduped
}

#[cfg(test)]
mod tests {
    use super::super::message_dto::MessageDto;
    use super::{ScopeCursor, dedupe_scopes, trim_messages_to_budget};
    use crate::ids::{ChannelId, MessageId, Seq};
    use crate::store::Message;

    fn message_of(len: usize) -> MessageDto {
        MessageDto::from(Message {
            id: MessageId::generate(),
            channel_id: ChannelId::generate(),
            author_id: None,
            author_display_name: None,
            seq: Seq(1),
            content: "x".repeat(len),
            created_at: 0,
            edited_at: None,
            reply_to_id: None,
        })
    }

    #[test]
    fn a_page_of_long_messages_is_cut_to_the_byte_budget_and_reports_more() {
        // Ten rows of 4000 bytes against a budget that fits three of them.
        let mut dtos: Vec<MessageDto> = (0..10).map(|_| message_of(4000)).collect();
        let mut budget = 3 * (4000 + 128) + 10;
        assert!(trim_messages_to_budget(&mut dtos, &mut budget));
        assert_eq!(dtos.len(), 3, "exactly the rows the budget paid for");
    }

    #[test]
    fn one_message_larger_than_the_whole_budget_is_still_admitted() {
        // Otherwise a single oversized message would stall the cursor forever.
        let mut dtos = vec![message_of(10_000), message_of(10)];
        let mut budget = 100;
        assert!(trim_messages_to_budget(&mut dtos, &mut budget));
        assert_eq!(dtos.len(), 1);
        assert_eq!(budget, 0, "an oversized admit spends the budget to zero");
    }

    #[test]
    fn a_page_that_fits_is_untouched_and_reports_nothing_more() {
        let mut dtos = vec![message_of(10), message_of(10)];
        let mut budget = 10_000;
        assert!(!trim_messages_to_budget(&mut dtos, &mut budget));
        assert_eq!(dtos.len(), 2);
    }

    fn sc(id: &str, after_seq: i64, after_op_seq: Option<i64>) -> ScopeCursor {
        ScopeCursor {
            channel_id: id.to_owned(),
            after_seq,
            after_op_seq,
        }
    }

    #[test]
    fn distinct_channels_pass_through_in_order() {
        let out = dedupe_scopes(vec![sc("a", 5, None), sc("b", 3, Some(1))]);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].channel_id, "a");
        assert_eq!(out[1].channel_id, "b");
    }

    /// A channel named twice collapses to the *smaller* seq, never the larger:
    /// syncing from the earlier point re-sends a little, but syncing from the
    /// later one would skip everything between the two - silent message loss.
    #[test]
    fn a_repeated_channel_keeps_the_smaller_seq() {
        let out = dedupe_scopes(vec![sc("a", 10, None), sc("a", 3, None)]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].after_seq, 3);

        // Order of arrival does not matter; the minimum still wins.
        let swapped = dedupe_scopes(vec![sc("a", 3, None), sc("a", 10, None)]);
        assert_eq!(swapped[0].after_seq, 3);
    }

    #[test]
    fn two_op_cursors_keep_the_smaller() {
        let out = dedupe_scopes(vec![sc("a", 5, Some(9)), sc("a", 5, Some(4))]);
        assert_eq!(out[0].after_op_seq, Some(4));
    }

    /// One side holding no op cursor must not erase the side that does: a
    /// present cursor is kept whichever order the two arrive in.
    #[test]
    fn a_present_op_cursor_survives_a_missing_one() {
        assert_eq!(
            dedupe_scopes(vec![sc("a", 5, None), sc("a", 5, Some(7))])[0].after_op_seq,
            Some(7)
        );
        assert_eq!(
            dedupe_scopes(vec![sc("a", 5, Some(7)), sc("a", 5, None)])[0].after_op_seq,
            Some(7)
        );
    }

    #[test]
    fn two_missing_op_cursors_stay_missing() {
        let out = dedupe_scopes(vec![sc("a", 5, None), sc("a", 8, None)]);
        assert_eq!(out[0].after_op_seq, None);
        assert_eq!(out[0].after_seq, 5);
    }
}
