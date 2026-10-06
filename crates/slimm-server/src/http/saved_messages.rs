// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Saved-message routes: save, unsave, and one person's own list.
//!
//! Private throughout. Unlike a pin, which is a moderation act on a channel
//! gated by MANAGE_MESSAGES, saving is something anyone does to their own
//! account: the only permission it needs is the one they already have to
//! read the message, and nobody - moderator or otherwise - can read, add to,
//! or count somebody else's list. There is no route here that takes a user
//! id, deliberately, so there is nothing to get wrong about whose list is
//! being served.
//!
//! No live event either. A save changes nothing anybody else can observe, so
//! fanning one out would be telling a channel something private about one of
//! its members.

use std::collections::HashSet;

use axum::Router;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, put};
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::message_enrich::with_reactions;
use super::messages::{MessageDto, parse_uuid};
use super::viewable_message::{NO_SUCH_MESSAGE, viewable_message};
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::SaveError;

/// The saved-message routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/messages/{message_id}/save", put(save).delete(unsave))
        .route("/saved", get(list))
}

/// A saved message: the full message, flattened, plus when it was kept.
/// Flattened for the same reason `PinDto` is - a client that already has a
/// `Message` model decodes this as one with an extra field.
#[derive(Serialize)]
struct SavedDto {
    #[serde(flatten)]
    message: MessageDto,
    /// When it was saved, not when it was sent. The list is ordered by this,
    /// so keeping an old message puts it at the top rather than the bottom.
    saved_at: i64,
}

/// Saves a message to the caller's own list, idempotently.
///
/// Needs only VIEW_CHANNEL on the message's channel: keeping something you
/// can read is not a further privilege. A message in a channel the caller
/// cannot see is refused as missing rather than forbidden, so this cannot be
/// used to probe for one - the same stance the message routes take.
async fn save(
    Authed(ctx): Authed,
    parts: Parts,
    Path(message_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let message_id = MessageId(parse_uuid(&message_id)?);
    viewable_message(&state, ctx.user_id, message_id).await?;
    // Mapped here the way pins::pin does: a ceiling is a 400, a missing message keeps the 404 an unviewable one gets.
    match state.store.save_message(ctx.user_id, message_id).await {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(SaveError::UnknownMessage) => Err(ApiError::NotFound(NO_SUCH_MESSAGE)),
        Err(SaveError::TooMany) => Err(ApiError::BadRequest(
            "you already have as many saved messages as an account can hold",
        )),
        Err(SaveError::Internal(e)) => Err(e.into()),
    }
}

/// Removes a message from the caller's own list.
///
/// Deliberately asks for no permission on the message's channel and does not
/// check the message still exists. Letting go of something is never
/// something to be refused: a member removed from a channel must still be
/// able to clear their own list of it, and a save whose message has since
/// been deleted is exactly the entry somebody most wants gone.
async fn unsave(
    Authed(ctx): Authed,
    parts: Parts,
    Path(message_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let message_id = MessageId(parse_uuid(&message_id)?);
    state.store.unsave_message(ctx.user_id, message_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// The caller's own saved messages, newest save first.
///
/// Filtered by what the caller can see *now*, not by what they could see
/// when they saved it. Access is revocable, and a private list is not a
/// licence to keep reading a channel somebody was removed from - so an entry
/// whose channel is no longer viewable is dropped from the answer rather
/// than served. The row stays: losing sight of a channel may be temporary,
/// and silently discarding somebody's saves on a permission change would be
/// destroying their data on a moderator's behalf.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<SavedDto>>, ApiError> {
    let saved = state.store.list_saved_messages(ctx.user_id).await?;

    let channel_ids: Vec<ChannelId> = saved
        .iter()
        .map(|s| s.message.channel_id)
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let permissions = state
        .store
        .permissions_in_channels(ctx.user_id, &channel_ids)
        .await?;

    let (visible, saved_at): (Vec<_>, Vec<i64>) = saved
        .into_iter()
        .filter(|s| {
            permissions
                .get(&s.message.channel_id)
                .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
        })
        .map(|s| (s.message, s.saved_at))
        .unzip();

    let dtos = with_reactions(&state, ctx.user_id, visible).await?;
    Ok(Json(
        dtos.into_iter()
            .zip(saved_at)
            .map(|(message, saved_at)| SavedDto { message, saved_at })
            .collect(),
    ))
}
