// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which messages an edit may rewrite: only one whose text is the message.

use super::super::AppState;
use super::super::error::ApiError;
use crate::ids::{MessageId, UserId};

/// Refuses an edit of a call record, a poll or an app launch: their text is not what they are,
/// and rewritten words would stand on a card the client draws for something else.
pub(super) async fn refuse_card_edit(
    state: &AppState,
    id: MessageId,
    author: UserId,
) -> Result<(), ApiError> {
    let ids = [id];
    let (calls, polls, apps) = tokio::try_join!(
        state.store.calls_for_messages(&ids),
        state.store.polls_for_messages(&ids, author),
        state.store.app_surfaces_for_messages(&ids),
    )?;
    if calls.is_empty() && polls.is_empty() && apps.is_empty() {
        return Ok(());
    }
    Err(ApiError::BadRequest(
        "only a text message can be edited, not a call, poll or app",
    ))
}
