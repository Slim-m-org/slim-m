// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The edit-history route, split out of `messages.rs` when adding
//! `mentions_me`'s own resolution step pushed that file past the 500-line
//! hard ceiling. Mounted from there rather than carrying its own `routes()`:
//! this is one handler, not a feature with a route table of its own.

use axum::extract::{Path, State};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::message_dto::MessageRevisionDto;
use super::parse_uuid;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;

/// Every version a message has held, oldest first, ending with its current
/// content. Gated on VIEW_CHANNEL like reading the message itself; a message
/// that does not exist, is not in this channel, or is deleted answers 404,
/// exactly as `messages::list` and `messages::edit` do.
pub(crate) async fn history(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageRevisionDto>>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);

    // Not being able to see the channel hides whether the message exists.
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::Forbidden);
    }

    // A live message in this channel, not merely a real id in some other one.
    let in_channel = state
        .store
        .message(message_id)
        .await?
        .is_some_and(|message| message.channel_id == channel_id);
    if !in_channel {
        return Err(ApiError::NotFound("message not found"));
    }

    let revisions = state
        .store
        .message_edit_history(message_id)
        .await?
        .ok_or(ApiError::NotFound("message not found"))?;
    Ok(Json(
        revisions
            .into_iter()
            .map(MessageRevisionDto::from)
            .collect(),
    ))
}
