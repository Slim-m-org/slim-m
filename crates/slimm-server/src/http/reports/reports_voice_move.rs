// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Names the two calls of a voice-move audit row for one reader.
//!
//! The row stores channel ids, so a reader who cannot view a call is told "a private channel"
//! and never its name. A row written before that holds names, which only an administrator reads.

use std::collections::HashMap;

use super::super::AppState;
use super::super::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;
use crate::store::ModerationHistoryItem;

const HIDDEN_NAME: &str = "a private channel";

fn parse_move(reason: &str) -> Option<(ChannelId, ChannelId)> {
    let (from, to) = reason.split_once(" to ")?;
    Some((ChannelId(from.parse().ok()?), ChannelId(to.parse().ok()?)))
}

async fn channel_name(
    state: &AppState,
    reader: UserId,
    administrator: bool,
    id: ChannelId,
    seen: &mut HashMap<ChannelId, String>,
) -> Result<String, ApiError> {
    if let Some(name) = seen.get(&id) {
        return Ok(name.clone());
    }
    let visible = administrator || state.store.viewed_channel_before_delete(reader, id).await?;
    let name = match visible {
        true => state
            .store
            .channel_including_deleted(id)
            .await?
            .map(|c| c.name),
        false => None,
    };
    let name = name.unwrap_or_else(|| HIDDEN_NAME.to_owned());
    seen.insert(id, name.clone());
    Ok(name)
}

/// Rewrites each voice-move row's reason into channel names the reader may see.
pub(super) async fn resolve_voice_moves(
    state: &AppState,
    reader: UserId,
    items: &mut [ModerationHistoryItem],
) -> Result<(), ApiError> {
    let administrator = state
        .store
        .base_permissions(reader)
        .await?
        .contains(Permissions::ADMINISTRATOR);
    let mut seen = HashMap::new();
    for item in items {
        let ModerationHistoryItem::Audit(entry) = item else {
            continue;
        };
        if entry.action != "voice_move" {
            continue;
        }
        entry.reason = match entry.reason.as_deref().and_then(parse_move) {
            Some((from, to)) => {
                let from = channel_name(state, reader, administrator, from, &mut seen).await?;
                let to = channel_name(state, reader, administrator, to, &mut seen).await?;
                Some(format!("{from} to {to}"))
            }
            None if administrator => entry.reason.take(),
            None => None,
        };
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_move;

    #[test]
    fn a_reason_of_two_ids_parses_and_a_name_pair_does_not() {
        let (a, b) = (uuid::Uuid::now_v7(), uuid::Uuid::now_v7());
        let parsed = parse_move(&format!("{a} to {b}")).unwrap();
        assert_eq!((parsed.0.0, parsed.1.0), (a, b));
        assert!(parse_move("lobby to games").is_none());
    }
}
