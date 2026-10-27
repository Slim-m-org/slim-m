// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `DELETE /channels/{id}/messages/{id}/link-previews`: remove the link-preview
//! cards from one message, for everyone.
//!
//! The author may do it to their own message, and a member holding
//! MANAGE_MESSAGES in the channel to anyone's. There is no way back: the cards
//! are fetched by the client per URL, so the only thing stored is the removal.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::delete;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/channels/{channel_id}/messages/{message_id}/link-previews",
            delete(remove),
        )
        .layer(DefaultBodyLimit::max(1024))
}

async fn remove(
    Authed(ctx): Authed,
    parts: Parts,
    Path((channel_id, message_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
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
    let message = state
        .store
        .message(message_id)
        .await?
        .filter(|m| m.channel_id == channel_id)
        .ok_or(ApiError::NotFound("message not found"))?;
    if message.author_id != Some(ctx.user_id)
        && !state
            .store
            .has_permission(ctx.user_id, channel_id, Permissions::MANAGE_MESSAGES)
            .await?
    {
        return Err(ApiError::Forbidden);
    }

    if state.store.suppress_link_previews(message_id).await? {
        state.hub.publish(Event::MessageLinkPreviewsRemoved {
            channel_id,
            message_id,
        });
    }
    Ok(StatusCode::NO_CONTENT)
}
