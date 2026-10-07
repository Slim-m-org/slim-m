// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wire envelope: every frame shape the WebSocket sends or accepts.
//!
//! Split out of `super` (the connect/authenticate/authorize/serve loop) once
//! that file reached the 500-line hard ceiling; the two halves were already
//! marked apart by their own `// --- Envelope ---` / `// --- Connection ---`
//! section comments before this existed.

use serde::{Deserialize, Serialize};

use crate::http::canvas::CanvasObjectDto;
use crate::http::channels::ChannelDto;
use crate::http::ephemeral_messages::EphemeralMessageDto;
use crate::http::messages::MessageDto;

#[derive(Serialize)]
#[serde(tag = "type")]
pub(super) enum ServerFrame {
    #[serde(rename = "hello")]
    Hello { protocol: u32, moderation_seq: u64 },
    #[serde(rename = "message.created")]
    MessageCreated {
        channel_id: String,
        seq: i64,
        message: MessageDto,
    },
    #[serde(rename = "message.edited")]
    MessageEdited {
        channel_id: String,
        /// The *message's* order key, unmoved by an edit. Not `op_seq`.
        seq: i64,
        #[serde(skip_serializing_if = "Option::is_none")]
        op_seq: Option<i64>,
        message: MessageDto,
    },
    #[serde(rename = "message.deleted")]
    MessageDeleted {
        channel_id: String,
        message_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        op_seq: Option<i64>,
    },
    #[serde(rename = "reactions.changed")]
    ReactionsChanged {
        channel_id: String,
        message_id: String,
        reactions: Vec<ReactionCountDto>,
    },
    #[serde(rename = "code_run.changed")]
    CodeRunChanged {
        channel_id: String,
        message_id: String,
        block_index: i64,
        module_id: String,
        command: String,
        ok: bool,
        output: String,
        ran_by: Option<String>,
        ran_at: i64,
    },
    /// Every run stored against this message was dropped because its content
    /// just changed; see [`crate::hub::Event::CodeRunsCleared`].
    #[serde(rename = "code_runs.cleared")]
    CodeRunsCleared {
        channel_id: String,
        message_id: String,
    },
    #[serde(rename = "thread.updated")]
    ThreadUpdated {
        channel_id: String,
        parent_message_id: String,
        thread_channel_id: String,
        reply_count: i64,
        #[serde(skip_serializing_if = "Option::is_none")]
        last_reply_at: Option<i64>,
    },
    #[serde(rename = "message.pinned")]
    MessagePinned {
        channel_id: String,
        message_id: String,
        pinned_by: Option<String>,
        pinned_at: i64,
    },
    #[serde(rename = "message.unpinned")]
    MessageUnpinned {
        channel_id: String,
        message_id: String,
    },
    #[serde(rename = "poll.voted")]
    PollVoted {
        channel_id: String,
        message_id: String,
        options: Vec<PollOptionCountDto>,
    },
    #[serde(rename = "message.components")]
    MessageComponentsChanged {
        channel_id: String,
        message_id: String,
        components: Vec<crate::components::ComponentRow>,
    },
    /// A member used this bot's button, menu entry or call control. Bot
    /// connections only. `custom_id` is the entry id for the latter two, and a
    /// call control names no message.
    #[serde(rename = "interaction.created")]
    InteractionCreated {
        interaction_id: String,
        channel_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
        custom_id: String,
        kind: String,
        user_id: String,
        user_display_name: String,
        created_at: i64,
    },
    /// The bot answered this account's click.
    #[serde(rename = "interaction.answered")]
    InteractionAnswered {
        interaction_id: String,
        channel_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
    },
    #[serde(rename = "presence.changed")]
    PresenceChanged {
        user_id: String,
        status: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        activity: Option<crate::presence_activity::Activity>,
    },
    #[serde(rename = "member.timeout")]
    MemberTimeoutChanged {
        user_id: String,
        until: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    #[serde(rename = "member.removed")]
    MemberRemoved {
        user_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    #[serde(rename = "member.restored")]
    MemberRestored {
        user_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    #[serde(rename = "member.joined")]
    MemberJoined { user_id: String },
    #[serde(rename = "profile.changed")]
    ProfileChanged { user_id: String },
    #[serde(rename = "bot_ui.changed")]
    BotUiChanged { bot_user_id: String },
    #[serde(rename = "typing.started")]
    TypingStarted { channel_id: String, user_id: String },
    #[serde(rename = "typing.stopped")]
    TypingStopped { channel_id: String, user_id: String },
    #[serde(rename = "role.changed")]
    RoleChanged {
        role_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    #[serde(rename = "member.role_changed")]
    MemberRoleChanged {
        user_id: String,
        role_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    #[serde(rename = "channel.created")]
    ChannelCreated { channel: ChannelDto },
    #[serde(rename = "channel.updated")]
    ChannelUpdated { channel: ChannelDto },
    #[serde(rename = "channel.deleted")]
    ChannelDeleted { channel_id: String },
    #[serde(rename = "overwrite.changed")]
    OverwriteChanged { channel_id: String },
    #[serde(rename = "category.changed")]
    CategoryChanged,
    #[serde(rename = "voice.activity")]
    VoiceActivityChanged { channel_id: String },
    /// See `docs/decisions/0032-voice-participant-webhooks.md`.
    #[serde(rename = "voice.participant_joined")]
    VoiceParticipantJoined { channel_id: String, user_id: String },
    #[serde(rename = "voice.participant_left")]
    VoiceParticipantLeft { channel_id: String, user_id: String },
    /// See [`crate::hub::Event::WatchTick`].
    #[serde(rename = "watch.tick")]
    WatchTick {
        channel_id: String,
        bot_user_id: String,
        ended: bool,
        item_id: String,
        playing: bool,
        position_ms: i64,
        sampled_at_ms: i64,
        epoch: i64,
    },
    #[serde(rename = "voice.screen_share_changed")]
    VoiceScreenShareChanged {
        channel_id: String,
        user_id: String,
        is_sharing_screen: bool,
    },
    /// A DM call ring started; see [`crate::hub::Event::CallRinging`].
    #[serde(rename = "call.ringing")]
    CallRinging {
        channel_id: String,
        ring_id: String,
        caller_id: String,
    },
    /// A DM call ring reached a terminal state; see
    /// [`crate::hub::Event::CallRingEnded`]. `outcome` is one of
    /// `answered`, `declined`, `canceled`, `timed_out`.
    #[serde(rename = "call.ring_ended")]
    CallRingEnded {
        channel_id: String,
        ring_id: String,
        outcome: String,
    },
    #[serde(rename = "canvas.object.placed")]
    CanvasObjectPlaced {
        channel_id: String,
        seq: i64,
        object: CanvasObjectDto,
    },
    #[serde(rename = "canvas.objects.removed")]
    CanvasObjectsRemoved {
        channel_id: String,
        seq: i64,
        op_id: String,
        object_ids: Vec<String>,
    },
    #[serde(rename = "canvas.cleared")]
    CanvasCleared {
        channel_id: String,
        seq: i64,
        op_id: String,
        before_seq: i64,
    },
    #[serde(rename = "canvas.objects.restored")]
    CanvasObjectsRestored {
        channel_id: String,
        seq: i64,
        op_id: String,
        object_ids: Vec<String>,
    },
    #[serde(rename = "canvas.cursor.moved")]
    CanvasCursorMoved {
        channel_id: String,
        user_id: String,
        x: f64,
        y: f64,
    },
    #[serde(rename = "canvas.stroke_preview.updated")]
    CanvasStrokePreview {
        channel_id: String,
        user_id: String,
        object_id: String,
        points: Vec<f64>,
        ended: bool,
    },
    #[serde(rename = "canvas.object.moved")]
    CanvasObjectMoved {
        channel_id: String,
        seq: i64,
        op_id: String,
        object_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    #[serde(rename = "canvas.object.reordered")]
    CanvasObjectReordered {
        channel_id: String,
        seq: i64,
        op_id: String,
        object_id: String,
        z_index: i64,
    },
    #[serde(rename = "canvas.media_slot.changed")]
    CanvasMediaSlotChanged {
        channel_id: String,
        kind: String,
        user_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        locked: bool,
        sent_to_back: bool,
    },
    /// The moderation queue changed: a report was filed or resolved. Carries
    /// nothing beyond the type tag; see [`crate::hub::Event::ReportsChanged`]
    /// for why. Delivered only to a connection whose user holds
    /// `MANAGE_MESSAGES`, per `http::ws::authorization` - this is a security
    /// boundary, not a visibility nicety.
    #[serde(rename = "reports.changed")]
    ReportsChanged,
    /// The account's read marker in a channel moved on some device; see
    /// [`crate::hub::Event::ReadStateChanged`]. Delivered only to that
    /// account's own connections.
    #[serde(rename = "read_state.changed")]
    ReadStateChanged {
        channel_id: String,
        last_read_seq: i64,
        manually_unread: bool,
    },
    /// The account's override for a channel was set or cleared on some
    /// device; see [`crate::hub::Event::NotificationOverrideChanged`].
    /// `preference` is null once the channel follows the account default.
    #[serde(rename = "notification_override.changed")]
    NotificationOverrideChanged {
        channel_id: String,
        preference: Option<String>,
    },
    /// A bot's private answer to this account; see
    /// [`crate::hub::Event::EphemeralMessage`]. Carries no `seq`.
    #[serde(rename = "message.ephemeral")]
    MessageEphemeral {
        channel_id: String,
        message: EphemeralMessageDto,
    },
    /// A device this account has not used before signed in; see
    /// [`crate::hub::Event::NewDeviceSignIn`]. Delivered only to the
    /// account's other devices.
    #[serde(rename = "device.signed_in")]
    NewDeviceSignIn {
        device_id: String,
        device_name: String,
        client_kind: Option<String>,
        signed_in_at: i64,
    },
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "error")]
    Error { message: String },
}

/// One emoji and how many people used it. Public counts only: what the asking
/// user reacted with is per viewer and never broadcast.
#[derive(Serialize)]
pub(crate) struct ReactionCountDto {
    pub(super) emoji: String,
    pub(super) count: i64,
}

/// One poll option and its current public vote count. Never carries who cast
/// a vote, only the option and its tally.
#[derive(Serialize)]
pub(crate) struct PollOptionCountDto {
    pub(super) position: i64,
    pub(super) votes: i64,
}

impl ServerFrame {
    /// Attaches a moderation number to the five frames that carry one.
    pub(super) fn with_moderation_seq(mut self, number: u64) -> Self {
        match &mut self {
            Self::MemberTimeoutChanged { seq, .. }
            | Self::MemberRemoved { seq, .. }
            | Self::MemberRestored { seq, .. }
            | Self::RoleChanged { seq, .. }
            | Self::MemberRoleChanged { seq, .. } => *seq = Some(number),
            _ => {}
        }
        self
    }
}

#[derive(Deserialize)]
#[serde(tag = "type")]
pub(super) enum ClientFrame {
    #[serde(rename = "hello")]
    Hello { ticket: String, protocol: u32 },
    #[serde(rename = "ping")]
    Ping,
    /// A typing refresh. Rate-limited and authorized like any other channel
    /// event (view plus send); see [`super::signals::handle_typing`]. There is
    /// no explicit "stop" frame: the state lapses on its own without a refresh.
    #[serde(rename = "typing")]
    Typing { channel_id: String },
    /// The channels this connection has open and focused right now, replacing
    /// its previous report; empty when none. Lapses after
    /// [`crate::viewing::VIEWING_TTL`], so a client refreshes it periodically.
    /// Used only to skip push for what this account is already reading.
    /// `active` says the user has used this device recently, which skips
    /// message pushes to their other devices for a short while.
    #[serde(rename = "viewing")]
    Viewing {
        channel_ids: Vec<String>,
        #[serde(default)]
        active: bool,
    },
    /// A pointer position on a channel's canvas. Rate-limited and authorized
    /// the same bar the canvas HTTP routes use (view plus `USE_CANVAS`); see
    /// [`super::signals::handle_canvas_cursor`]. No "stop" frame either, for
    /// the reason [`crate::hub::Event::CanvasCursorMoved`] gives.
    #[serde(rename = "canvas.cursor")]
    CanvasCursor { channel_id: String, x: f64, y: f64 },
    /// An in-flight stroke preview on a channel's canvas. Rate-limited by the
    /// frame's own byte size rather than by count, and authorized on the same
    /// bar the canvas write route uses (view plus `USE_CANVAS`, plus a direct
    /// timeout check a cursor frame does not need, since this one carries
    /// drawing content); see
    /// [`super::signals::handle_canvas_stroke_preview`].
    #[serde(rename = "canvas.stroke_preview")]
    CanvasStrokePreview {
        channel_id: String,
        object_id: String,
        points: Vec<f64>,
        #[serde(default)]
        ended: bool,
    },
}
