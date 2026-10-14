// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One write for everything `PATCH /channels/{id}` can change, so a failure
//! cannot leave some fields applied and the rest not.

use sqlx::QueryBuilder;

use super::{Channel, Store};
use crate::ids::ChannelId;

/// The fields a channel update may set; `None` leaves a field untouched.
#[derive(Default)]
pub struct ChannelPatch<'a> {
    pub name: Option<&'a str>,
    /// `Some(None)` clears the topic.
    pub topic: Option<Option<&'a str>>,
    pub slow_mode_seconds: Option<i64>,
    /// A default, not a lock: SPEAK overwrites are what restrict speaking.
    pub join_muted: Option<bool>,
    /// Voice only: a lobby that makes a room per person (decision 0065).
    pub creates_rooms: Option<bool>,
    /// Voice only: the most people in the call, 0 for no limit.
    pub user_limit: Option<i64>,
    /// Rooms only: nobody new may join.
    pub room_locked: Option<bool>,
}

impl ChannelPatch<'_> {
    fn is_empty(&self) -> bool {
        self.name.is_none()
            && self.topic.is_none()
            && self.slow_mode_seconds.is_none()
            && self.join_muted.is_none()
            && self.creates_rooms.is_none()
            && self.user_limit.is_none()
            && self.room_locked.is_none()
    }
}

impl Store {
    /// Applies `patch` in one statement. `None` means nothing matched: the
    /// channel is missing, deleted, a DM or a thread, the same guard
    /// [`Store::update_channel`] applies.
    pub async fn update_channel_settings(
        &self,
        id: ChannelId,
        patch: ChannelPatch<'_>,
    ) -> anyhow::Result<Option<Channel>> {
        let mut builder = QueryBuilder::new("UPDATE channels SET ");
        let mut set = builder.separated(", ");
        if let Some(name) = patch.name {
            set.push("name = ").push_bind_unseparated(name.to_owned());
        }
        if let Some(topic) = patch.topic {
            set.push("topic = ")
                .push_bind_unseparated(topic.map(str::to_owned));
        }
        if let Some(seconds) = patch.slow_mode_seconds {
            set.push("slow_mode_seconds = ")
                .push_bind_unseparated(seconds);
        }
        if let Some(join_muted) = patch.join_muted {
            set.push("join_muted = ").push_bind_unseparated(join_muted);
        }
        if let Some(creates_rooms) = patch.creates_rooms {
            set.push("creates_rooms = ")
                .push_bind_unseparated(creates_rooms);
        }
        if let Some(limit) = patch.user_limit {
            set.push("user_limit = ").push_bind_unseparated(limit);
        }
        if let Some(locked) = patch.room_locked {
            set.push("room_locked = ").push_bind_unseparated(locked);
        }
        if patch.is_empty() {
            return self.update_channel(id, None, None).await;
        }
        builder.push(" WHERE id = ").push_bind(id);
        builder.push(" AND deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL");
        let affected = builder.build().execute(&self.pool).await?.rows_affected();
        if affected == 0 {
            return Ok(None);
        }
        self.channel(id).await
    }
}
