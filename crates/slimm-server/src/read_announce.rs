// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Moving an account's read marker and telling its other devices, for callers that hold a
//! `Store` and a `Hub` rather than the HTTP state.

use crate::hub::{Event, Hub};
use crate::ids::{ChannelId, UserId};
use crate::store::Store;

/// Advances `user_id`'s marker in `channel_id` and fans the stored marker out to that account's
/// own sessions. A mark that moves nothing publishes nothing: the frame wakes every socket.
pub(crate) async fn advance_and_announce(
    store: &Store,
    hub: &Hub,
    user_id: UserId,
    channel_id: ChannelId,
    seq: i64,
) -> anyhow::Result<()> {
    if let Some(last_read_seq) = store.mark_read(user_id, channel_id, seq).await? {
        hub.publish(Event::ReadStateChanged {
            user_id,
            channel_id,
            last_read_seq,
            manually_unread: false,
        });
    }
    Ok(())
}
