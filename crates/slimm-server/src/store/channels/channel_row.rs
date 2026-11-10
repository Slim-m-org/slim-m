// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one row shape every `channels` read maps through, so a new column is added to
//! [`ChannelRow`] and its [`Channel`] conversion once; each `query_as!` that selects it then
//! fails to compile until it names the column too.

use crate::ids::{ChannelCategoryId, ChannelId, MessageId, UserId};
use crate::notifications::NotificationPreference;
use crate::store::{Channel, ChannelRoom};

/// The `channels` columns a [`Channel`] is built from, named as the queries alias them.
#[derive(sqlx::FromRow)]
pub(in crate::store) struct ChannelRow {
    pub id: ChannelId,
    pub name: String,
    pub kind: String,
    pub topic: Option<String>,
    pub position: i64,
    pub parent_message_id: Option<MessageId>,
    pub category_id: Option<ChannelCategoryId>,
    pub created_at: i64,
    pub slow_mode_seconds: i64,
    pub join_muted: bool,
    pub default_notification: String,
    pub creates_rooms: bool,
    pub user_limit: i64,
    pub room_owner_id: Option<UserId>,
    pub room_lobby_id: Option<ChannelId>,
    pub room_locked: bool,
}

/// The unqualified column list for a raw `SELECT` that builds [`ChannelRow`]s.
pub(in crate::store) const CHANNEL_COLUMNS: &str = "id, name, kind, topic, position, \
    parent_message_id, category_id, created_at, slow_mode_seconds, join_muted, \
    default_notification, creates_rooms, user_limit, room_owner_id, room_lobby_id, room_locked";

impl From<ChannelRow> for Channel {
    fn from(row: ChannelRow) -> Self {
        Channel {
            id: row.id,
            name: row.name,
            kind: row.kind,
            topic: row.topic,
            position: row.position,
            parent_message_id: row.parent_message_id,
            category_id: row.category_id,
            created_at: row.created_at,
            slow_mode_seconds: row.slow_mode_seconds,
            join_muted: row.join_muted,
            default_notification: NotificationPreference::parse(&row.default_notification)
                .unwrap_or_default(),
            room: ChannelRoom {
                creates_rooms: row.creates_rooms,
                user_limit: row.user_limit,
                owner_id: row.room_owner_id,
                lobby_id: row.room_lobby_id,
                locked: row.room_locked,
            },
        }
    }
}
