// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reaction routes: add and remove one emoji on one message.
//!
//! Both are idempotent, because the client that most needs them is the one on
//! a bad connection retrying. Reacting twice leaves one reaction; removing a
//! reaction that is not there succeeds, since the caller's intent ("this emoji
//! of mine is gone") already holds.
//!
//! The emoji is a path segment rather than a body, so the two verbs are a plain
//! PUT and DELETE on the same resource. A GET on it lists who left the
//! reaction, per viewer; see `docs/decisions/0051-who-reacted.md`.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::put;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::messages::parse_uuid;
use super::viewable_message::viewable_message;
use crate::hub::Event;
use crate::ids::MessageId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{ReactError, ReactorCursor};

/// Nothing here carries a body; the emoji is in the path.
const BODY_LIMIT: usize = 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/messages/{message_id}/reactions/{emoji}",
            put(add).delete(remove).get(list_reactors),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// Resolves the message and checks the caller may both see and react in its
/// channel. Returns the channel so the caller can publish to it.
///
/// Viewing is checked as well as reacting, because a reaction is otherwise a
/// probe: reacting to an id and seeing it succeed would confirm a message
/// exists in a channel the caller cannot read.
async fn authorize(
    state: &AppState,
    user_id: crate::ids::UserId,
    message_id: MessageId,
) -> Result<crate::ids::ChannelId, ApiError> {
    let (message, permissions) = viewable_message(state, user_id, message_id).await?;
    if !permissions.contains(Permissions::ADD_REACTIONS) {
        return Err(ApiError::Forbidden);
    }
    Ok(message.channel_id)
}

async fn add(
    Authed(ctx): Authed,
    parts: Parts,
    Path((message_id, emoji)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let message_id = MessageId(parse_uuid(&message_id)?);
    let channel_id = authorize(&state, ctx.user_id, message_id).await?;
    if !super::reaction_emoji::is_reaction(&emoji) {
        return Err(ApiError::BadRequest("that is not a usable emoji"));
    }

    match state
        .store
        .add_reaction(message_id, ctx.user_id, &emoji)
        .await
    {
        Ok(()) => {}
        Err(ReactError::UnknownMessage) => return Err(ApiError::NotFound("no such message")),
        Err(ReactError::InvalidEmoji) => {
            return Err(ApiError::BadRequest("that is not a usable emoji"));
        }
        Err(ReactError::TooManyDistinctEmoji) => {
            return Err(ApiError::BadRequest(
                "this message already has as many different reactions as it can hold",
            ));
        }
        Err(ReactError::Internal(e)) => return Err(e.into()),
    }

    publish(&state, channel_id, message_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path((message_id, emoji)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let message_id = MessageId(parse_uuid(&message_id)?);
    let channel_id = authorize(&state, ctx.user_id, message_id).await?;

    state
        .store
        .remove_reaction(message_id, ctx.user_id, &emoji)
        .await?;
    publish(&state, channel_id, message_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Tells live connections the message's reactions changed.
///
/// Reads the raw reactors once here, rather than once per receiving
/// connection: `reactors` rides the internal [`Event`] but never the wire, and
/// each connection still derives its own per-viewer tally from it at send
/// time in `ws.rs` (the same shape `presence.changed` uses for a status), by
/// reading the blocklist fresh against `reactors` rather than trusting a
/// count computed here. A precomputed *tally* fanned out unfiltered from here
/// is what previously let a live reaction quietly undo a block: the client
/// replaces its cached tally with whatever a frame says. Carrying raw
/// reactors instead of a tally keeps that per-connection filtering step
/// mandatory.
///
/// `reacted` is likewise absent from the wire and derived per client, so one
/// connection is never told what another user reacted with beyond the count.
async fn publish(
    state: &AppState,
    channel_id: crate::ids::ChannelId,
    message_id: MessageId,
) -> Result<(), ApiError> {
    let reactors = state.store.reaction_reactors(message_id).await?;
    state.hub.publish(Event::ReactionsChanged {
        channel_id,
        message_id,
        reactors,
    });
    Ok(())
}

const DEFAULT_PAGE: i64 = 50;
const MAX_PAGE: i64 = 100;

#[derive(Deserialize)]
struct ReactorParams {
    limit: Option<i64>,
    after: Option<String>,
}

#[derive(Serialize)]
struct Reactor {
    user_id: String,
}

#[derive(Serialize)]
struct ReactorPage {
    users: Vec<Reactor>,
    next_cursor: Option<String>,
}

/// `<reacted_at ms>.<user uuid>`: opaque to clients, strict to parse.
fn parse_cursor(raw: &str) -> Result<ReactorCursor, ApiError> {
    let bad = || ApiError::BadRequest("after is not a cursor this route returned");
    let (at, user) = raw.split_once('.').ok_or_else(bad)?;
    Ok(ReactorCursor {
        created_at: at.parse().map_err(|_| bad())?,
        user_id: crate::ids::UserId(user.parse().map_err(|_| bad())?),
    })
}

/// Lists who left one reaction, as the caller may see them.
///
/// Read access to the message is the whole gate, answered as a missing message
/// when it fails. The list goes through the same block filter as the tally, so
/// it never names someone the count leaves out. Identity still never rides the
/// WebSocket frame; this is a per-viewer read.
async fn list_reactors(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path((message_id, emoji)): Path<(String, String)>,
    Query(params): Query<ReactorParams>,
    State(state): State<AppState>,
) -> Result<Json<ReactorPage>, ApiError> {
    let message_id = MessageId(parse_uuid(&message_id)?);
    let after = params.after.as_deref().map(parse_cursor).transpose()?;
    let limit = params.limit.unwrap_or(DEFAULT_PAGE).clamp(1, MAX_PAGE);
    viewable_message(&state, ctx.user_id, message_id).await?;

    let mut rows = state
        .store
        .reaction_reactor_page(message_id, ctx.user_id, &emoji, after, limit + 1)
        .await?;
    let has_more = rows.len() as i64 > limit;
    rows.truncate(limit as usize);
    let next_cursor = rows
        .last()
        .filter(|_| has_more)
        .map(|last| format!("{}.{}", last.created_at, last.user_id));
    Ok(Json(ReactorPage {
        users: rows
            .into_iter()
            .map(|r| Reactor {
                user_id: r.user_id.to_string(),
            })
            .collect(),
        next_cursor,
    }))
}
