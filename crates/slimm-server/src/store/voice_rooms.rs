// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Temporary voice rooms (decision 0065): a lobby makes one room per person,
//! a copy of its overwrites included, and an emptied room is removed.

use uuid::Uuid;

use super::{Channel, Store, now_ms};
use crate::ids::{ChannelId, UserId};

impl Store {
    /// `owner`'s live room from `lobby`, if they already have one.
    pub async fn voice_room_of(
        &self,
        lobby: ChannelId,
        owner: UserId,
    ) -> anyhow::Result<Option<Channel>> {
        let id = sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE room_lobby_id = ? AND room_owner_id = ? AND deleted_at IS NULL
               ORDER BY created_at LIMIT 1"#,
            lobby,
            owner
        )
        .fetch_optional(&self.pool)
        .await?;
        match id {
            Some(id) => self.channel(id).await,
            None => Ok(None),
        }
    }

    /// Creates `owner`'s room beside `lobby`: same category and position
    /// (created later, so it sorts right after the lobby), and a copy of the
    /// lobby's overwrites, so exactly the same people can see it.
    pub async fn create_voice_room(
        &self,
        lobby: &Channel,
        owner: UserId,
        name: &str,
    ) -> anyhow::Result<Channel> {
        let id = ChannelId(Uuid::now_v7());
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        sqlx::query!(
            "INSERT INTO channels
                (id, name, kind, position, created_at, category_id, room_owner_id, room_lobby_id)
             VALUES (?, ?, 'voice', ?, ?, ?, ?, ?)",
            id,
            name,
            lobby.position,
            now,
            lobby.category_id,
            owner,
            lobby.id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny)
             SELECT ?, target_type, target_id, allow, deny
             FROM channel_overwrites WHERE channel_id = ?",
            id,
            lobby.id
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
            id,
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.channel(id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("the room just created is missing"))
    }

    /// Live rooms created before `before_ms`, for the sweep that removes the
    /// ones nobody is in.
    pub async fn voice_rooms_created_before(
        &self,
        before_ms: i64,
    ) -> anyhow::Result<Vec<ChannelId>> {
        Ok(sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE (room_owner_id IS NOT NULL OR room_lobby_id IS NOT NULL)
                 AND deleted_at IS NULL AND created_at < ?"#,
            before_ms
        )
        .fetch_all(&self.pool)
        .await?)
    }
}
