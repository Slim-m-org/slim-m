// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's claim that a message re-posts a member's words, so that member's blockers are spared it.

use super::super::AppState;
use super::super::error::ApiError;
use super::parse_uuid;
use crate::ids::UserId;

/// The member a send names as the source of its text, only when the sender is a bot.
///
/// A person's claim is discarded, as `embeds` are. A bot naming anyone but a live person is a 400,
/// so a typo cannot silently leave a repost unmasked.
pub(super) async fn honored(
    state: &AppState,
    caller: UserId,
    raw: Option<&str>,
) -> Result<Option<UserId>, ApiError> {
    let Some(raw) = raw else { return Ok(None) };
    if !state.store.is_bot(caller).await? {
        return Ok(None);
    }
    let author = UserId(parse_uuid(raw)?);
    if !state.store.is_live_person(author).await? {
        return Err(ApiError::BadRequest(
            "repost_of_author_id must name a member",
        ));
    }
    Ok(Some(author))
}
