// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The [`Event`] enum: every fact `Hub::publish` can carry to a connection.
//!
//! Split out of `hub.rs` once that file reached the 500-line hard ceiling;
//! `Event`'s own doc comments are the closest thing this protocol has to a
//! spec for what a live frame may say, which is why none of them were
//! shortened to make room instead.

use std::sync::Arc;

use crate::ephemeral::EphemeralMessage;
use crate::ids::{CallRingId, ChannelId, DeviceId, RoleId, SessionId, UserId};
use crate::store::Channel;
use crate::voice::CallRingOutcome;

mod canvas;
mod message;
mod presence_change;
mod role_change;

pub use canvas::CanvasEvent;
pub use message::MessageEvent;
pub use presence_change::PresenceChange;
pub use role_change::{RoleChange, RoleLook};

/// Something that happened and should reach interested connections.
#[derive(Debug, Clone)]
pub enum Event {
    /// A canvas fact; see [`CanvasEvent`].
    Canvas(CanvasEvent),
    /// A message fact; see [`MessageEvent`].
    Message(MessageEvent),
    /// A session was revoked; any live connection on it must close at once.
    SessionRevoked(SessionId),
    /// A user's live connection count transitioned to or from zero, or their
    /// visibility preference changed while connected. Carries only the user
    /// id: each connection derives its own per-viewer status at delivery time
    /// (see `http::ws::authorize`), so a hidden user's true state is never
    /// present in the event payload, only in the answer computed for one
    /// specific viewer.
    PresenceChanged(PresenceChange),
    /// A member was timed out, or their timeout was lifted. `until` is Unix
    /// milliseconds, or `None` for a lift.
    ///
    /// Deployment-wide rather than channel-scoped, and carrying the deadline
    /// rather than only an id: unlike presence there is nothing per-viewer to
    /// derive, since the badge is the same fact for everyone who can see the
    /// member at all. Without this a timed-out member's composer stays
    /// enabled and their sends start failing with 403, which reads as the app
    /// being broken rather than as something a moderator did.
    MemberTimeoutChanged { user_id: UserId, until: Option<i64> },
    /// A member accepted the rules, or (`None`) the join gate's settings
    /// changed. Either moves what a pending member may see, so every client
    /// re-asks what it is allowed to do; it carries no rules text.
    JoinGateChanged { user_id: Option<UserId> },
    /// A member was removed from the Space. Their own sockets close on the
    /// `SessionRevoked` events that accompany this; everyone else's member
    /// list uses this to drop them without waiting for a refetch.
    MemberRemoved(UserId),
    /// A removed member was let back in. The mirror of
    /// [`Event::MemberRemoved`], for the session that watched them vanish:
    /// without it a remove-then-restore leaves the member invisible in every
    /// already-open client until an unrelated refetch.
    MemberRestored(UserId),
    /// Somebody actually joined the Space: registration, or an existing
    /// account spending an invite code (`Store::redeem_invite`). Not
    /// published for a restore from removal, which already has
    /// [`Event::MemberRestored`] and is not a new member.
    ///
    /// Carries only the id, the shape [`Event::MemberRemoved`] already uses:
    /// a receiving connection re-fetches the member from `GET /members` for
    /// anything more than that, the same reason a greeter bot resolves the
    /// rest of a profile over REST rather than this event carrying it.
    ///
    /// Does not move `hub::moves_permissions`: unlike a restore, a new
    /// member's arrival changes no other connection's already-cached answer
    /// for any channel it holds, since nobody was ever told "no" for this
    /// user first.
    MemberJoined(UserId),
    /// A user changed their display name. Carries only the id, the shape
    /// [`Event::MemberRemoved`] already uses: the name itself lives in
    /// exactly one place, `users.display_name`, and a receiving connection
    /// re-asks `GET /users/{id}` rather than trusting a second copy riding
    /// the wire. This is what closes the debt recorded against
    /// `messages.author_display_name` - a message row already cached
    /// locally used to show whatever name was true when it arrived, forever;
    /// the client re-resolves a message's author against this event instead
    /// of trusting that stored copy for the rest of the session.
    ProfileChanged(UserId),
    /// A bot replaced its message menu entries or call controls. Carries only
    /// the bot, like [`Event::ProfileChanged`]: each client refetches the bot
    /// UI for the channels it has open, and that read applies the channel's
    /// own visibility, so nothing is masked per reader on the live path.
    BotUiChanged(UserId),
    /// Someone started or refreshed typing in a channel.
    TypingStarted {
        channel_id: ChannelId,
        user_id: UserId,
    },
    /// A typing state ended, either by lapsing on its own without a refresh
    /// or an explicit end; the two are indistinguishable on the wire. See
    /// `crate::typing`.
    TypingStopped {
        channel_id: ChannelId,
        user_id: UserId,
    },
    /// A role was created, renamed, had its permission bits changed, or was
    /// deleted. Never carries the permission bits: those are gated behind
    /// MANAGE_ROLES over REST (`GET /roles`), and broadcasting them here would
    /// hand every member a privileged answer this event has no way to check
    /// them against. The name is not secret, members see it in the member
    /// list, and `change` adds the member-visible look
    /// (name, colour, hoist, mentionable) either side of the change when the
    /// publisher knows it. Deployment-wide like
    /// [`Event::MemberTimeoutChanged`] for the same reason: a role's bits feed
    /// every channel's evaluation at once, so there is no bounded per-channel
    /// audience to compute instead. A receiving client cannot resolve what
    /// changed, only that it should re-ask what it is now allowed to do.
    RoleChanged {
        role_id: RoleId,
        change: Option<Arc<RoleChange>>,
    },
    /// A role was granted to or revoked from a member. Carries both ids,
    /// which leaks nothing beyond `GET /members` already does for any caller:
    /// a member's held role ids are on their public profile. Broadcast rather
    /// than gated on the receiver for the same reason [`Event::MemberRemoved`]
    /// is: the fact itself is not privileged, only a role's bits are, and
    /// those never travel here either.
    MemberRoleChanged {
        user_id: UserId,
        role_id: RoleId,
        granted: bool,
        role_name: Option<String>,
    },
    /// A channel was created. Carries the full row, the way
    /// [`Event::MessageCreated`] carries its message: a fresh channel has no
    /// prior state to reconcile against, so whoever can view it right now is
    /// exactly who should be told, the same channel-scoped check every
    /// message event already uses. `Arc`-wrapped for the same reason.
    ///
    /// The `bool` is `restricted`: the same for every reader, so it rides
    /// the event once and delivery is still decided per subscriber.
    ChannelCreated(Arc<Channel>, bool),
    /// A channel was renamed, had its topic replaced, or moved in the
    /// deployment's order. Never changes what a channel's permission model
    /// allows, so the ordinary current-state channel-scoped check is exact
    /// here too: nobody's view of the channel changes, only its name, topic
    /// or position. `PUT /channels/order` publishes one of these per channel
    /// whose position actually moved, reusing this rather than a new variant.
    /// `Arc`-wrapped like [`Event::ChannelCreated`]: the two are matched
    /// together everywhere in `http::ws::authorization`, so only one of them
    /// staying a plain `Channel` would reintroduce the deep clone anyway.
    ChannelUpdated(Arc<Channel>, bool),
    /// A channel was soft-deleted. Carries only the id: there is nothing left
    /// to show once it is gone. Gated specially in `http::ws::authorize`
    /// rather than through the ordinary channel-scoped check, which would
    /// always answer "no such channel" the instant this fires and so would
    /// never reach anyone - see
    /// [`crate::store::Store::viewed_channel_before_delete`].
    ChannelDeleted { channel_id: ChannelId },
    /// A category was created, renamed, repositioned, or deleted. Carries no
    /// fields at all, the plainest form of the "re-ask what changed" shape
    /// [`Event::RoleChanged`] already uses: a category is organisational
    /// only (see docs/decisions/0006-channel-categories.md), so there is
    /// nothing privileged to withhold and nothing per-viewer to resolve -
    /// unlike a role's bits, a category's name and position are exactly what
    /// `GET /channels` already hands every viewer unfiltered. A receiving
    /// client re-fetches the channel list, the same path a channel create,
    /// rename, or delete already drives.
    CategoryChanged,
    /// A deployment-wide Space display setting changed; carries nothing, a client re-reads `/version`.
    SpaceSettingsChanged,
    /// A channel permission overwrite was set or cleared for one role or one
    /// member. Carries only the channel id: the allow/deny mask is exactly
    /// the kind of privileged detail [`Event::RoleChanged`] withholds, and for
    /// the same reason. Gated by the ordinary current-state channel-scoped
    /// check, so a viewer who gains access is told immediately; a viewer
    /// whose access this exact change revokes is a known, accepted gap (see
    /// the audit finding this closes), since telling them precisely would need
    /// the same kind of pre-change snapshot [`Event::ChannelDeleted`] needed,
    /// scaled to however many members a role-targeted overwrite can name.
    OverwriteChanged {
        channel_id: ChannelId,
        /// Who could view the channel immediately *before* this overwrite was
        /// written, among the members it affects.
        ///
        /// Carried because the ordinary per-viewer check answers the question
        /// one instant too late: a connection whose view this very change
        /// revoked now fails it, so gating on the current answer alone delivers
        /// to everyone except the people the change was about - and their rail
        /// keeps showing a channel they can no longer open, which is the whole
        /// symptom this event exists to fix.
        ///
        /// It leaks nothing. Every id in it is somebody who could see the
        /// channel a moment ago, and the frame carries only the channel id.
        /// Bounded by the targeted role's membership, or by one for a member
        /// overwrite.
        previously_visible_to: Arc<Vec<UserId>>,
    },
    /// Someone's presence on a channel's voice call changed: a first
    /// heartbeat for a `(user, channel)` pair (a join), a clean hangup's
    /// forgotten heartbeat, or the stale-heartbeat sweep evicting someone.
    /// Carries only the channel id, never who.
    ///
    /// This is a deliberate departure from [`Event::ThreadUpdated`], which
    /// carries its whole current answer: a thread's reply count is the same
    /// for every viewer, while a voice roster is not.
    /// `GET .../voice/roster` drops a participant whose
    /// `presence_visibility` is hidden from every viewer but themselves, and
    /// an id-only event is what keeps that guarantee structural rather than
    /// something a future edit to this event's payload could get wrong. A
    /// receiving connection re-fetches the roster, which already applies
    /// that per-viewer filtering, instead of being told who moved.
    VoiceActivityChanged { channel_id: ChannelId },
    /// A LiveKit webhook reported someone joined a channel's voice room.
    /// See `docs/decisions/0032-voice-participant-webhooks.md` for why this
    /// names the participant where `VoiceActivityChanged` deliberately does
    /// not: authorized per subscriber on the joiner's own presence
    /// visibility, the same guarantee the roster route already gives.
    VoiceParticipantJoined {
        channel_id: ChannelId,
        user_id: UserId,
    },
    /// The same webhook-sourced signal as [`Event::VoiceParticipantJoined`],
    /// for a participant leaving.
    VoiceParticipantLeft {
        channel_id: ChannelId,
        user_id: UserId,
    },
    /// The room's watch position, re-sampled by the bot running the watch
    /// party about every 5 seconds and on every play, pause or seek.
    ///
    /// Ephemeral by the reasons [`Event::CanvasCursorMoved`] gives: no `seq`,
    /// never persisted, and a receiver that misses one is corrected by the
    /// next. The durable copy is `watch_sessions`, which a late joiner or a
    /// reconnect reads over REST. `ended` marks the bot's own end of the
    /// session; a bot that just stops ticking is over once the session's
    /// lifetime passes, so a receiver still treats silence as the end.
    /// `bot_user_id` and the epoch together name which session this belongs to.
    WatchTick {
        channel_id: ChannelId,
        bot_user_id: UserId,
        ended: bool,
        item_id: String,
        playing: bool,
        position_ms: i64,
        sampled_at_ms: i64,
        epoch: i64,
    },
    /// A participant started or stopped sharing their screen, per LiveKit's
    /// `track_published`/`track_unpublished` webhooks. See
    /// `docs/decisions/0032-voice-participant-webhooks.md`.
    VoiceScreenShareChanged {
        channel_id: ChannelId,
        user_id: UserId,
        is_sharing_screen: bool,
    },
    /// A call-audio session started, changed or ended (decision 0105), for
    /// everyone who can view the channel. `state` is `None` once it ends, and
    /// `ended` then says how: `declined`, `lapsed`, `stopped` and so on, never
    /// who. Never persisted and unnumbered; the REST route is the catch-up.
    CallAudioChanged {
        channel_id: ChannelId,
        state: Option<Box<crate::call_audio::CallAudioView>>,
        ended: Option<&'static str>,
    },
    /// Ringing was started for a DM call: `caller_id` is calling whoever the
    /// other side of the `channel_id` DM is. `ring_id` names this specific
    /// attempt so a receiving client can tell it apart from an immediate
    /// retry, and so [`Event::CallRingEnded`] can name exactly which ring it
    /// concerns.
    ///
    /// Reaches only the two DM participants, the ordinary `VIEW_CHANNEL`
    /// check every voice event already uses - a DM's own permission model
    /// (`store/dms.rs`) grants that to nobody else, `ADMINISTRATOR` included.
    /// A blocked party is refused before this is ever published: `CONNECT`
    /// is one of the bits a block removes, and starting a ring is gated on
    /// it the same way minting a token already is.
    CallRinging {
        channel_id: ChannelId,
        ring_id: CallRingId,
        caller_id: UserId,
    },
    /// A ring (started by [`Event::CallRinging`]) reached a terminal state:
    /// answered, declined, canceled by the caller, or timed out unanswered.
    /// See [`CallRingOutcome`] for what each means and
    /// `voice::ring`'s own module doc for why the ring itself is tracked
    /// in memory rather than persisted.
    CallRingEnded {
        channel_id: ChannelId,
        ring_id: CallRingId,
        outcome: CallRingOutcome,
    },
    /// A group DM's roster or custom name changed. Carries only the channel
    /// id: a receiving client re-reads its DM list, which already applies
    /// per-viewer nicknames. Reaches the current participants through the
    /// ordinary `VIEW_CHANNEL` check, so it is the roster as it is now that
    /// decides, and a person who just left learns from their own request.
    DmChanged { channel_id: ChannelId },
    /// A report was filed or resolved: the moderation queue changed and a
    /// moderator watching it should refetch.
    ///
    /// Carries nothing at all, deliberately - a report's content, reporter and
    /// subject must never fan out to a live connection the way `ReportDto`'s
    /// own doc comment already forbids over REST. `http::ws::authorization`
    /// gates this event per viewer, delivering it only to a connection whose
    /// user holds `MANAGE_MESSAGES` and withholding it from everyone else;
    /// this is the one event in the file for which that gate is a security
    /// boundary rather than a visibility nicety, since every other
    /// deployment-wide event here (`RoleChanged`, `CategoryChanged`,
    /// `MemberTimeoutChanged`) is already fine to broadcast unfiltered.
    ReportsChanged,
    /// An operator alert opened or recovered. Carries nothing: a holder of
    /// `MANAGE_SERVER` who has not muted alerts refetches `GET /space/alerts`.
    /// `http::ws::authorization` withholds it from everyone else.
    AdminAlertsChanged,
    /// One account's read marker in a channel moved, from any of its devices.
    ///
    /// Private to `user_id`: `http::ws::authorization` delivers it only to that
    /// account's own connections and withholds it from everyone else, so it is
    /// the signal that clears a badge on the other devices and never a read
    /// receipt (those stay deferred). Carries the marker itself rather than
    /// "changed", because the marker is monotonic and applying it needs no read.
    ReadStateChanged {
        user_id: UserId,
        channel_id: ChannelId,
        last_read_seq: i64,
        manually_unread: bool,
    },
    /// One account's per-channel notification override was set or cleared.
    ///
    /// Private to `user_id`, delivered like [`Event::ReadStateChanged`]. `None`
    /// means the channel follows the account default again.
    NotificationOverrideChanged {
        user_id: UserId,
        channel_id: ChannelId,
        preference: Option<crate::notifications::NotificationPreference>,
    },
    /// A bot answered a member privately.
    ///
    /// Private to `recipient_id`: `http::ws::authorization` delivers it only to
    /// that account's own connections, and only while it can still view the
    /// channel. It has no `seq` and is never stored, so it can leave no gap in a
    /// channel's ordering and cannot appear in a page, a search or a `/sync`.
    EphemeralMessage {
        recipient_id: UserId,
        message: Arc<EphemeralMessage>,
    },
    /// A member pressed a button. Private to the owning bot: only its own
    /// connections receive it, and nothing is stored beyond the click row.
    InteractionCreated {
        interaction: Arc<crate::store::Interaction>,
        clicker_display_name: String,
        /// What was chosen or typed; carried by the event and never stored.
        input: Arc<crate::store::InteractionInput>,
    },
    /// The bot opened a form for a click. Private to the clicker, whose client
    /// shows it.
    InteractionForm {
        interaction: Arc<crate::store::Interaction>,
        form: Arc<crate::components::form::Form>,
    },
    /// The bot answered a click. Private to the clicker, so the pressed
    /// button can leave its pending state.
    InteractionAnswered {
        interaction: Arc<crate::store::Interaction>,
    },
    /// A device this account has not used before just signed in.
    ///
    /// Private to `user_id` and withheld from the connection of `device_id`
    /// itself, which is the one that just signed in. Durable rather than
    /// ephemeral: it is rare and a security notice, so it must not be the
    /// thing a lagging socket skips past.
    NewDeviceSignIn {
        user_id: UserId,
        device_id: DeviceId,
        device_name: String,
        client_kind: Option<String>,
        signed_in_at: i64,
    },
    /// A moderator moved `user_id` from one call to another. Private to the
    /// moved account, whose clients switch rooms; everyone else learns of it
    /// from the ordinary join and leave events.
    VoiceMoved {
        user_id: UserId,
        from_channel_id: ChannelId,
        to_channel_id: ChannelId,
        to_channel_name: String,
        moved_by_id: UserId,
        moved_by_name: String,
    },
    /// Someone started a call, joined one or went live in a channel `user_id` asked to hear
    /// about. Private to `user_id`; the audience and the time limit are settled before this
    /// is published (decision 0107).
    VoiceNotice {
        user_id: UserId,
        channel_id: ChannelId,
        actor_id: UserId,
        activity: crate::voice_notify::Activity,
    },
    /// A voice session closed. Internal: only the module event consumer reads
    /// it, and no websocket frame is ever built from it.
    VoiceSessionClosed {
        session_id: i64,
        user_id: UserId,
        channel_id: ChannelId,
        joined_at_ms: i64,
        left_at_ms: i64,
        alone_ms: i64,
    },
    /// A moderation event with its number, added by [`crate::hub::Hub::publish`]
    /// and never built by a handler. See `hub::moderation_seq`.
    Stamped { seq: u64, event: Box<Event> },
}
