// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Direct-message conversations: listing the caller's own, opening (or
//! returning) the one with another user - or, naming yourself, your own
//! personal space - and closing one out of the caller's own list (see
//! `crate::store::dms`).
//!
//! A DM is a channel under the hood (kind `dm`), so once one is open, every
//! other message operation - send, list, edit, delete, react, search, mark
//! read, sync, and the WebSocket fan-out - already works against it through
//! the ordinary `/channels/{channelId}/...` routes with no code of its own:
//! see `crate::store::dms` for why that channel's permissions do not run
//! through the deployment's role/overwrite evaluator. This module only
//! covers what is specific to a DM rather than any channel: discovering the
//! conversation list, and turning a target user id into a channel id.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::{DmConversation, MemberGate, OpenDmError, User};

const BODY_LIMIT: usize = 1024;

/// The direct-message routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/dms", get(list))
        .route("/dms/{user_id}", post(open).delete(hide))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

// --- Wire types ---

#[derive(Serialize)]
struct DmConversationDto {
    channel_id: String,
    user: ParticipantDto,
    unread: i64,
    created_at: i64,
}

/// The other participant's public profile. The same narrow shape
/// `/users/{userId}` returns, redeclared here rather than shared: the two
/// modules have no reason to stay in lockstep beyond happening to agree on
/// what a public profile looks like today.
#[derive(Serialize)]
struct ParticipantDto {
    id: String,
    username: String,
    display_name: String,
    created_at: i64,
}

impl From<User> for ParticipantDto {
    fn from(user: User) -> Self {
        Self {
            id: user.id.to_string(),
            username: user.username,
            display_name: user.display_name,
            created_at: user.created_at,
        }
    }
}

impl From<DmConversation> for DmConversationDto {
    fn from(conversation: DmConversation) -> Self {
        Self {
            channel_id: conversation.channel_id.to_string(),
            user: conversation.other.into(),
            unread: conversation.unread,
            created_at: conversation.created_at,
        }
    }
}

// --- Handlers ---

/// Lists the caller's DM conversations, most recently active first.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<DmConversationDto>>, ApiError> {
    let mut conversations = state.store.list_dm_conversations(ctx.user_id).await?;
    let ids: Vec<UserId> = conversations.iter().map(|c| c.other.id).collect();
    let nicknames = state.store.nicknames_for(&ids).await?;
    for conversation in &mut conversations {
        if let Some(nickname) = nicknames.get(&conversation.other.id) {
            conversation.other.display_name.clone_from(nickname);
        }
    }
    Ok(Json(
        conversations
            .into_iter()
            .map(DmConversationDto::from)
            .collect(),
    ))
}

/// Opens (or returns) the DM channel with another user, or - passing the
/// caller's own id - their personal space.
///
/// Idempotent and race-safe on the store side (see
/// [`crate::store::Store::open_dm`]), so two clients opening the same pair at
/// once converge on one channel rather than creating two.
async fn open(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<DmConversationDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    // The gate caps what a DM may do, but would still let one be created.
    if state.store.member_gate(ctx.user_id).await? != MemberGate::Member {
        return Err(ApiError::ForbiddenBecause("accept the rules first"));
    }

    let channel = match state.store.open_dm(ctx.user_id, target).await {
        Ok(channel) => channel,
        Err(OpenDmError::UserNotFound) => return Err(ApiError::NotFound("user not found")),
        // The same answer whichever direction blocked, so a caller learns
        // only that the DM is refused, never who blocked whom.
        Err(OpenDmError::Blocked) => return Err(ApiError::Forbidden),
        Err(OpenDmError::Internal(e)) => return Err(e.into()),
    };

    let mut other = state
        .store
        .user_profile(target)
        .await?
        .ok_or(ApiError::NotFound("user not found"))?;
    if let Some(nickname) = state.store.nicknames_for(&[target]).await?.remove(&target) {
        other.display_name = nickname;
    }
    let unread = state.store.unread_count(ctx.user_id, channel.id).await?;
    Ok(Json(DmConversationDto {
        channel_id: channel.id.to_string(),
        user: other.into(),
        unread,
        created_at: channel.created_at,
    }))
}

/// Closes a DM out of the caller's own sidebar - a per-viewer hide, never a
/// delete: no message is touched, and the other participant's own list is
/// unaffected (see [`crate::store::Store::hide_dm_conversation`]).
///
/// Idempotent, and a no-op rather than a `404` when the pair has no channel:
/// the caller asked for "not in my list", which is already true.
async fn hide(
    Authed(ctx): Authed,
    parts: Parts,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let target = UserId(parse_uuid(&user_id)?);
    state
        .store
        .hide_dm_conversation(ctx.user_id, target)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
