// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing temporary voice rooms once their call is empty (decision 0065),
//! from the voice webhook and from a sweep that catches a missed webhook.

use crate::hub::{Event, Hub};
use crate::ids::ChannelId;
use crate::store::{Store, now_ms};
use crate::voice::{VoiceError, VoiceService};

/// A room younger than this is never swept, so one just made is not removed
/// before its owner's client has joined it.
pub const ROOM_GRACE_MS: i64 = 60_000;

/// Deletes `channel_id` when it is a room and LiveKit reports nobody in its
/// call. Never deletes on doubt: an SFU that cannot answer keeps the room.
pub async fn remove_if_empty(store: &Store, voice: &VoiceService, hub: &Hub, channel_id: ChannelId) {
    let Ok(Some(channel)) = store.channel(channel_id).await else {
        return;
    };
    if !channel.room.is_room() {
        return;
    }
    match voice.list_participants(channel_id).await {
        Ok(list) if list.is_empty() => {}
        Ok(_) | Err(VoiceError::Unavailable) => return,
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not check whether a voice room is empty");
            return;
        }
    }
    match store.delete_channel(channel_id).await {
        Ok(true) => {
            let _ = voice.delete_room(channel_id).await;
            hub.publish(Event::ChannelDeleted { channel_id });
        }
        Ok(false) => {}
        Err(err) => tracing::warn!(?err, "could not remove an empty voice room"),
    }
}

/// Removes every room past its grace period that nobody is in.
pub async fn sweep_empty_rooms(store: &Store, voice: &VoiceService, hub: &Hub) {
    let rooms = match store.voice_rooms_created_before(now_ms() - ROOM_GRACE_MS).await {
        Ok(rooms) => rooms,
        Err(err) => {
            tracing::warn!(%err, "could not list voice rooms to sweep");
            return;
        }
    };
    for room in rooms {
        remove_if_empty(store, voice, hub, room).await;
    }
}
