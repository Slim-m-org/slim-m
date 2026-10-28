// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The domain rows shared across every feature submodule.

use crate::ids::{ChannelCategoryId, ChannelId, MessageId, Seq, UserId};

/// A channel (a text or voice room).
#[derive(Debug, Clone)]
pub struct Channel {
    pub id: ChannelId,
    pub name: String,
    pub kind: String,
    /// A one-line description shown beside the name in the client's channel
    /// header. `None` for no topic; an edit to a blank value normalizes to
    /// `None`, since an empty topic and no topic render the same.
    pub topic: Option<String>,
    /// Sort key among the deployment's live, non-DM channels: lower sorts
    /// first. Deployment-wide, not per-device - see
    /// [`crate::store::channel_order::reorder_channels`]. Meaningless for a DM,
    /// which is never listed or reordered by it.
    pub position: i64,
    /// The message this channel is a thread of, or `None` for an ordinary
    /// channel. A thread's own `kind` and overwrites are never consulted for
    /// permissions: see [`super::Store::permission_channel`], which resolves them
    /// live from this message's own `channel_id` instead, per
    /// docs/decisions/0005-threads.md. A thread never appears in
    /// [`super::Store::list_channels`].
    pub parent_message_id: Option<MessageId>,
    /// The rail section this channel is filed under, or `None` for
    /// uncategorised - rendered as an implicit section above every named
    /// one. Decides placement only, never behaviour: see
    /// docs/decisions/0006-channel-categories.md. A category carries no
    /// permissions of its own, so this column is never consulted by
    /// [`super::Store::permission_channel`] or anything it calls.
    pub category_id: Option<ChannelCategoryId>,
    pub created_at: i64,
    /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
    /// wait between their own messages here. 0 means off. Never read for a DM
    /// or a thread, neither of which exposes a setter for it - see
    /// [`crate::store::channel_slow_mode::Store::update_channel_slow_mode`].
    pub slow_mode_seconds: i64,
    /// Voice-channel default that every client opens its mic off on join. A
    /// default, not a lock: SPEAK overwrites are what restrict speaking. See
    /// [`crate::store::channel_settings::Store::update_channel_settings`].
    pub join_muted: bool,
    /// What members with no choice of their own for this channel get; see
    /// `docs/decisions/0049-notification-override-badge.md`.
    pub default_notification: crate::notifications::NotificationPreference,
    /// Temporary voice rooms and the user limit; see decision 0065.
    pub room: ChannelRoom,
}

/// A voice channel's room settings (decision 0065): all off for every other
/// channel, which is what [`Default`] gives.
#[derive(Debug, Clone, Default)]
pub struct ChannelRoom {
    /// This voice channel is a lobby that makes a room per person.
    pub creates_rooms: bool,
    /// The most people its call takes, 0 for no limit.
    pub user_limit: i64,
    /// Set on a room: who it belongs to.
    pub owner_id: Option<UserId>,
    /// Set on a room: the lobby that made it.
    pub lobby_id: Option<ChannelId>,
    /// Nobody new may join the room's call.
    pub locked: bool,
}

impl ChannelRoom {
    /// Whether this channel is a temporary room rather than a fixed channel.
    pub fn is_room(&self) -> bool {
        self.owner_id.is_some() || self.lobby_id.is_some()
    }
}

/// A rail section: a channel of any kind may be filed under one, per
/// docs/decisions/0006-channel-categories.md. Organisational only - it
/// grants and denies no permission, see docs/IMPLIED-GAPS.md.
#[derive(Debug, Clone)]
pub struct ChannelCategory {
    pub id: ChannelCategoryId,
    pub name: String,
    /// Sort key among the deployment's live categories: lower sorts first.
    /// Uncategorised channels render above every named category regardless
    /// of this value, since they carry no category row to hold one.
    pub position: i64,
    pub created_at: i64,
}

/// A user account's public profile. Deliberately narrow: id, username,
/// display name, and creation time only. Nothing from the auth tables
/// (password hash, sessions, tokens) has a type that could even be confused
/// with this one.
#[derive(Debug, Clone)]
pub struct User {
    pub id: UserId,
    pub username: String,
    pub display_name: String,
    pub created_at: i64,
    /// When the caller's current avatar was set, or `None` for no avatar.
    /// Not a foreign key to anything: the bytes live on disk keyed by user
    /// id, not content-addressed like a message attachment (see migration
    /// 0013). A client uses the value only as a cache-busting version
    /// appended to the fetch URL.
    pub avatar_updated_at: Option<i64>,
    /// When the caller's profile banner image was set, or `None` for the colour; migration 0137.
    pub banner_updated_at: Option<i64>,
    /// A short free-text status line ("in a meeting", "afk"), or `None` for
    /// none set. Rides alongside `display_name` (migration 0044): set from
    /// personal settings, shown in the member pane under the name, and
    /// carries no independent live event - `Event::ProfileChanged` already
    /// covers it the same way it covers a rename.
    pub status_text: Option<String>,
    /// A short self-described pronoun set ("she/her"), or `None` if unset.
    /// Shown on the member card beside the `@handle`; see migration 0075.
    pub pronouns: Option<String>,
    /// A short free-text "about" line (190 characters), or `None` if unset.
    /// Shown on the member card under the status line; see migration 0075.
    pub about: Option<String>,
    /// An index into the design system's closed categorical colour set
    /// (`AppCanvasColors.cursors`, six hues), or `None` for the default. Never
    /// a raw colour: an index keeps meaning a fixed hue in both themes. See
    /// migration 0075.
    pub profile_color: Option<i64>,
    /// A custom colour as 0xRRGGBB, or `None` to use [`Self::profile_color`];
    /// see migration 0120.
    pub profile_color_rgb: Option<i64>,
    /// Whether this account is a bot rather than a person, so a reader can be
    /// told without inspecting anything. See
    /// `docs/decisions/0028-bot-accounts.md`; it changes how the account
    /// authenticates and how it is labelled, never what it may do.
    pub is_bot: bool,
    /// Whether this account is a webhook's principal rather than a person or
    /// a bot. See `docs/decisions/0030-incoming-webhooks.md`; like `is_bot`
    /// it changes how the account authenticates (a webhook has no session at
    /// all) and how it is labelled, never what it may do - except that a
    /// webhook holds no roles in the first place, so there is nothing for it
    /// to do beyond posting through its one delivery route.
    pub is_webhook: bool,
}

/// A message. `author_id` is null once the author's account is anonymized.
///
/// The author's display name rides along with the message rather than being
/// looked up per author by the client, which would be a request per distinct
/// sender in a channel. It is null for the same reason `author_id` is: the
/// account was anonymized, and there is no name left to show.
#[derive(Debug, Clone)]
pub struct Message {
    pub id: MessageId,
    pub channel_id: ChannelId,
    pub author_id: Option<UserId>,
    pub author_display_name: Option<String>,
    pub seq: Seq,
    pub content: String,
    pub created_at: i64,
    pub edited_at: Option<i64>,
    /// The message this one replies to, if any. Always in this same channel:
    /// [`super::Store::send_message`] refuses any other target at write time. The
    /// parent's own content, author and liveness are never copied here -
    /// resolve them by looking that id up like any other message, so a
    /// later edit or delete of the parent is never something a reply's own
    /// row could go stale about.
    pub reply_to_id: Option<MessageId>,
}
