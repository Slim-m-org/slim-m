// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The single-message fetch route, split out of `messages.rs` when adding it
//! pushed that file past the 500-line hard ceiling. Mounted from there rather
//! than carrying its own `routes()`: this is one handler, not a feature with
//! a route table of its own - the same shape `message_history.rs` already
//! uses for the same reason.

use axum::extract::{Path, State};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{AUTHED_READ, AuthedLimited, Json};
use super::message_dto::MessageDto;
use super::parse_uuid;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;

/// Fetches one message, enriched exactly like a page from `messages::list` -
/// the same batched reactions/attachments/thread/embed lookups, just over a
/// single id, so a caller that only saw a reaction or a reply for a message
/// it never cached does not have to go through search or list paging to
/// read it.
///
/// Authorized like `list` (VIEW_CHANNEL in `channel_id`), but answers 404
/// rather than 403 when that check fails - unlike list, this route's whole
/// point is a caller naming one specific id, so a 403 here would confirm the
/// channel exists while a 404 does not. "No such channel", "not permitted
/// here" and "no such message" all answer identically, the same
/// existence-oracle avoidance `channel_permissions.rs` and `threads.rs`
/// already use for their own single-target reads.
pub(crate) async fn get_message(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<MessageDto>, ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let message_id = MessageId(parse_uuid(&message_id)?);
    if !state
        .store
        .has_permission(ctx.user_id, channel_id, Permissions::VIEW_CHANNEL)
        .await?
    {
        return Err(ApiError::NotFound("message not found"));
    }

    let message = state
        .store
        .message(message_id)
        .await?
        .filter(|m| m.channel_id == channel_id)
        .ok_or(ApiError::NotFound("message not found"))?;
    let mut dtos =
        super::message_enrich::with_reactions(&state, ctx.user_id, vec![message]).await?;
    Ok(Json(dtos.remove(0)))
}
