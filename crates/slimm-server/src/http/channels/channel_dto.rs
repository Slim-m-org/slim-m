// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The channel wire shape, shared with the live `channel.*` frames.

use serde::Serialize;

use crate::store::Channel;

/// `pub(crate)` so `http::ws` can reuse the exact same wire shape for the
/// live `channel.created`/`channel.updated` frames, the way `MessageDto`
/// already does for messages.
#[derive(Serialize)]
pub(crate) struct ChannelDto {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) kind: String,
    /// `null` for no topic. A client shows this as a one-line description
    /// beside the channel name; absence and an empty topic are treated as
    /// the same thing, so this is never `Some("")` - see
    /// [`validate_channel_topic`].
    pub(super) topic: Option<String>,
    /// Sort key among the deployment's live, non-DM channels: lower sorts
    /// first. Set via `PUT /channels/order`, deployment-wide rather than
    /// per-device. Meaningless on a DM, which never appears in this list.
    pub(super) position: i64,
    /// The message this channel is a thread of, or `null` for an ordinary
    /// channel. A thread's own `kind` and permissions are never what govern
    /// it: `VIEW_CHANNEL`/`SEND_MESSAGES` here inherit the parent message's
    /// own channel, resolved live rather than copied - see
    /// docs/decisions/0005-threads.md. A thread never appears in
    /// `listChannels`; reach one through `openThread`.
    pub(super) parent_message_id: Option<String>,
    /// The rail section this channel is filed under, or `null` for
    /// uncategorised - rendered as an implicit section above every named
    /// category. Decides placement only: see
    /// docs/decisions/0006-channel-categories.md. Absent on servers older
    /// than this field, which a client must treat as unknown rather than
    /// assuming uncategorised.
    pub(super) category_id: Option<String>,
    pub(super) created_at: i64,
    /// The caller's own effective permission bitmask in this channel,
    /// already resolved through thread and DM handling with any timeout
    /// subtracted - the batched sibling of `GET
    /// /channels/{channelId}/permissions`. Present only on `listChannels`:
    /// every row there already carries VIEW_CHANNEL by construction, so
    /// unlike the dedicated route this needs no existence-probe mask, and
    /// it costs no extra query since `Store::visible_channels_with_permissions`
    /// already computes it. Absent (not `Some(0)`) from create, update,
    /// reorder, and the live `channel.created`/`channel.updated` frames:
    /// none of those has one single caller whose bitmask would be right to
    /// embed, and a live frame in particular fans out to many receivers
    /// holding different permissions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) permissions: Option<i64>,
    /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
    /// wait between their own messages here. 0 means off - see
    /// `channel_slow_mode::enforce_slow_mode`. Always present, unlike
    /// `permissions`: every channel has one value for this, not one per
    /// caller, so there is no reason to omit it anywhere `ChannelDto`
    /// appears.
    pub(super) slow_mode_seconds: i64,
    /// Whether joining this voice channel starts with the mic off. A
    /// default members can override, not a lock; always present.
    pub(super) join_muted: bool,
    /// What members with no choice of their own get here: `everything`,
    /// `mentions` or `nothing`. Always present.
    pub(super) default_notification: &'static str,
    /// A voice lobby that makes a room per person; see decision 0065.
    pub(super) creates_rooms: bool,
    /// The most people a voice channel's call takes, 0 for no limit.
    pub(super) user_limit: i64,
    /// Set only on a temporary room: who owns it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) room_owner_id: Option<String>,
    /// Set only on a temporary room: whether nobody new may join.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) room_locked: Option<bool>,
    /// Whether `@everyone` lacks VIEW_CHANNEL here, so the channel is hidden
    /// from ordinary members rather than visible to anyone in the
    /// deployment. Identical for every caller, unlike `permissions` - see
    /// `Store::channel_permissions_all`. Present only on `listChannels`, for
    /// the same reason `permissions` is: no other response has a channel row
    /// worth annotating this way.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) restricted: Option<bool>,
}

impl From<Channel> for ChannelDto {
    fn from(channel: Channel) -> Self {
        Self {
            id: channel.id.to_string(),
            name: channel.name,
            kind: channel.kind,
            topic: channel.topic,
            position: channel.position,
            parent_message_id: channel.parent_message_id.map(|id| id.to_string()),
            category_id: channel.category_id.map(|id| id.to_string()),
            created_at: channel.created_at,
            permissions: None,
            slow_mode_seconds: channel.slow_mode_seconds,
            join_muted: channel.join_muted,
            default_notification: channel.default_notification.as_str(),
            creates_rooms: channel.room.creates_rooms,
            user_limit: channel.room.user_limit,
            room_owner_id: channel.room.owner_id.map(|id| id.to_string()),
            room_locked: channel.room.is_room().then_some(channel.room.locked),
            restricted: None,
        }
    }
}

impl ChannelDto {
    /// A channel row with the reader-independent `restricted` fact attached.
    pub(crate) fn with_restricted(channel: Channel, restricted: bool) -> Self {
        Self {
            restricted: Some(restricted),
            ..Self::from(channel)
        }
    }
}
