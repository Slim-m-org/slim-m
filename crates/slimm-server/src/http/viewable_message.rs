// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Loading a message by id for a caller who must be able to see it.

use super::AppState;
use super::error::ApiError;
use crate::ids::{MessageId, UserId};
use crate::permissions::Permissions;
use crate::store::Message;

/// The 404 text for a message that is missing or that the caller cannot see.
pub(super) const NO_SUCH_MESSAGE: &str = "no such message";

/// The message and the caller's permissions in its channel, or a 404 that a
/// hidden message shares with a missing one so the route cannot be used to
/// probe for a message in a channel the caller cannot read.
pub(super) async fn viewable_message(
    state: &AppState,
    user_id: UserId,
    message_id: MessageId,
) -> Result<(Message, Permissions), ApiError> {
    let Some(message) = state.store.message(message_id).await? else {
        return Err(ApiError::NotFound(NO_SUCH_MESSAGE));
    };
    let permissions = state
        .store
        .permissions_in_channel(user_id, message.channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::NotFound(NO_SUCH_MESSAGE));
    }
    Ok((message, permissions))
}
