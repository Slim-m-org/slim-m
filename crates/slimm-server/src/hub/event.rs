// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The [`Event`] enum: every fact `Hub::publish` can carry to a connection.
//!
//! Split out of `hub.rs` once that file reached the 500-line hard ceiling;
//! `Event`'s own doc comments are the closest thing this protocol has to a
//! spec for what a live frame may say, which is why none of them were
//! shortened to make room instead.

use std::sync::Arc;

use crate::components::ComponentRow;
use crate::ephemeral::EphemeralMessage;
use crate::ids::{
    CallRingId, CanvasObjectId, CanvasOpId, ChannelId, DeviceId, MessageId, RoleId, Seq, SessionId,
    UserId,
};
use crate::store::{
    AppSurface, AttachmentSummary, CallRecord, CanvasObject, Channel, CodeRunSummary, Embed,
    ForwardSummary, MediaSlotKind, Message, Poll,
};
use crate::voice::CallRingOutcome;

/// Something that happened and should reach interested connections.
#[derive(Debug, Clone)]
pub enum Event {
    /// A message was created; carries the full row so a connection can render
    /// the wire frame without another query.
    ///
    /// Attachments ride along because a brand new message can already have
    /// them and the row cannot express them. The sender reads them once for
    /// its own response, so this costs no extra query; leaving them out sent
    /// an image that only appeared on the next sync. `message`, `attachments`
    /// and `forwarded` are `Arc`-wrapped so a `broadcast` fan-out clones a
    /// refcount, not this whole row, for a connection that filters it out.
    MessageCreated {
        message: Arc<Message>,
        attachments: Arc<Vec<AttachmentSummary>>,
        /// Present when the message forwards something. Rides along for the
        /// same reason `attachments` does: the row cannot express it, and a
        /// forward that arrived live without it rendered as a bare note
        /// until the next sync filled the origin in.
        forwarded: Option<Arc<ForwardSummary>>,
        /// The app this message launches, if any - resolved once here by the
        /// sender rather than per subscriber, the same reasoning `attachments`
        /// carries this rather than each connection querying it. See
        /// `http::ws::message_frames::created`.
        app_surface: Option<Arc<AppSurface>>,
        /// The app's block-0 run, if one already landed by the time this
        /// message was sent - a client can race its first run against the
        /// send that made the message it targets. `None` here is not "no
        /// run yet": a run that lands after this event still arrives its
        /// own `CodeRunChanged`.
        code_run: Option<Arc<CodeRunSummary>>,
        /// The poll this message carries, if any. `voted_option` is always
        /// `None` here: nobody can have voted before this message, which is
        /// the poll's own creation, exists.
        poll: Option<Arc<Poll>>,
        /// Raw, like `attachments`; image tokens resolve per connection.
        embeds: Arc<Vec<Embed>>,
        /// The call this message records, if any. Resolved once by the
        /// publisher that just wrote it rather than looked up per subscriber:
        /// nothing in it depends on who is reading.
        call: Option<Arc<CallRecord>>,
        /// The buttons a bot posted with the message; see decision 0039.
        components: Arc<Vec<ComponentRow>>,
    },
    /// A message was edited. `op_seq` is its place in the *message-op* stream,
    /// a different sequence from the message's own `seq`, which an edit does
    /// not move; the two sit adjacent in one frame.
    MessageEdited {
        message: Message,
        op_seq: i64,
        /// Present when the edited message forwards something. An edit
        /// changes the note, never what was forwarded, so this repeats the
        /// origin rather than implying it went: a receiver applying the
        /// frame writes what it is given, and a frame that omitted this
        /// would read as "no longer a forward".
        forwarded: Option<ForwardSummary>,
    },
    /// A poll's votes changed. Carries the whole per-option tally rather than
    /// a delta, so a client that missed a frame cannot drift, exactly like
    /// `ReactionsChanged`; who cast which vote is deliberately never present.
    PollVoted {
        channel_id: ChannelId,
        message_id: MessageId,
        options: Vec<(i64, i64)>,
    },
    /// A bot replaced or cleared the buttons on its message. Carries the whole
    /// list, like `PollVoted`, so a client that missed a frame cannot drift.
    MessageComponentsChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        components: Arc<Vec<ComponentRow>>,
    },
    /// A message was soft-deleted; carries only the ids a live connection
    /// needs to drop it from view, not the content it no longer shows.
    MessageDeleted {
        channel_id: ChannelId,
        message_id: MessageId,
        /// This delete's place in the message-op stream, absent when the
        /// delete found nothing to do.
        op_seq: Option<i64>,
    },
    /// A message's reactions changed. The tally itself stays per viewer, since
    /// a reactor the receiver has blocked is not counted for them, so it is
    /// still derived per receiving connection at send time the way
    /// [`Event::PresenceChanged`]'s status is - `reactors` below only saves
    /// that derivation a repeat store read.
    ///
    /// `reactors` carries every reactor of the message, grouped by emoji, each
    /// paired with its own reaction time rather than a pre-reduced `first_at` -
    /// the raw fact this event exists to broadcast, read once via
    /// [`crate::store::Store::reaction_reactors`] rather than once per
    /// receiving connection. It exists on this internal enum only:
    /// [`crate::http::ws::frames::ServerFrame::ReactionsChanged`] carries
    /// emoji and count alone, never a reactor id or a timestamp, and each
    /// receiving connection is responsible for turning this shared,
    /// unfiltered answer into its own view with a fresh
    /// [`crate::store::Store::blocked_among`] read before it is allowed
    /// anywhere near the wire - excluding a blocked reactor there, and
    /// re-deriving that viewer's own `first_at` from what is left, since the
    /// per-viewer emoji ordering a blocked reactor's early timestamp must not
    /// be able to shift. A precomputed tally broadcast unfiltered is exactly
    /// what made a live reaction undo a block; carrying the raw reactors
    /// instead of a tally keeps that filtering step mandatory rather than
    /// optional.
    ///
    /// The reactor snapshot is taken once, at publish time in
    /// `http/reactions.rs`, not at delivery time per connection. Reactions
    /// are eventually consistent by design (decision 0009: a live frame
    /// overwrites the one row it names, and a reconnect clears and refetches
    /// rather than reconciling), and this event carries no sequence number,
    /// so two reactions on the same message published close together can
    /// reach a connection out of order and leave a briefly wrong count on
    /// screen; the next reaction on that message, or a reconnect, corrects
    /// it. A strict fix would need a per-message reaction sequence number,
    /// deliberately out of scope here.
    ReactionsChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        reactors: Vec<(String, Vec<(UserId, i64)>)>,
    },
    /// A fenced code block was run and its shared output changed. Carries the
    /// whole current result (the [`Event::ThreadUpdated`] shape), overwriting
    /// the one `(message_id, block_index)` row everywhere. Nothing per-viewer,
    /// unlike [`Event::ReactionsChanged`]: the output is the same for everyone
    /// with VIEW_CHANNEL, so it is delivered as-is. No seq, eventually
    /// consistent; a reconnect refetches via `message_enrich::with_reactions`.
    CodeRunChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        block_index: i64,
        module_id: String,
        command: String,
        ok: bool,
        output: String,
        ran_by: Option<UserId>,
        ran_at: i64,
    },
    /// Every stored run for a message was dropped because its content just
    /// changed underneath them; see `store::messages::edit_message`. No block
    /// index: an edit can add or remove a block above another one, shifting
    /// every later block's index, so this clears the whole message at once
    /// rather than naming a block a shifted index could get wrong. A viewer's
    /// cached run cannot fall out of a `MessageEdited` frame on its own (that
    /// frame's bare DTO is merged, never used to shrink what a client already
    /// holds - see `message_extras.dart`), so this is the explicit signal to
    /// drop it.
    CodeRunsCleared {
        channel_id: ChannelId,
        message_id: MessageId,
    },
    /// A thread's reply summary changed: it was just opened, or gained a
    /// reply. Carries the current `reply_count`/`last_reply_at` rather than a
    /// delta, the "whole current answer" shape [`Event::PollVoted`] already
    /// uses, so a client that missed a frame cannot drift.
    ///
    /// `channel_id` is the *parent* channel, not the thread's own: that is
    /// the channel a bystander's connection is actually gated on, per
    /// [`crate::store::Store::permission_channel`]'s own resolution, and it
    /// is what lets the ordinary channel-scoped check in `http::ws::authorize`
    /// apply here unchanged rather than needing a thread-aware branch.
    ///
    /// Unlike [`Event::ReactionsChanged`], the count is carried directly
    /// rather than re-derived per receiving connection: the batch load a REST
    /// fetch already uses
    /// ([`crate::store::Store::thread_summaries_for_messages`]) answers the
    /// same count to every viewer regardless of blocking, so precomputing it
    /// here does not create the per-viewer inconsistency that made an
    /// unfiltered reaction tally a bug.
    ThreadUpdated {
        channel_id: ChannelId,
        parent_message_id: MessageId,
        thread_channel_id: ChannelId,
        reply_count: i64,
        last_reply_at: Option<i64>,
    },
    /// A message was pinned in a channel.
    MessagePinned {
        channel_id: ChannelId,
        message_id: MessageId,
        /// Null once the pinner's account is anonymized.
        pinned_by: Option<UserId>,
        pinned_at: i64,
    },
    /// A message was unpinned.
    MessageUnpinned {
        channel_id: ChannelId,
        message_id: MessageId,
    },
    /// A session was revoked; any live connection on it must close at once.
    SessionRevoked(SessionId),
    /// A user's live connection count transitioned to or from zero, or their
    /// visibility preference changed while connected. Carries only the user
    /// id: each connection derives its own per-viewer status at delivery time
    /// (see `http::ws::authorize`), so a hidden user's true state is never
    /// present in the event payload, only in the answer computed for one
    /// specific viewer.
    PresenceChanged(UserId),
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
    /// deleted. Carries only the id, never the name or the bits: those are
    /// gated behind MANAGE_ROLES over REST (`GET /roles`), and broadcasting
    /// either here would hand every member a privileged answer this event has
    /// no way to check them against. Deployment-wide like
    /// [`Event::MemberTimeoutChanged`] for the same reason: a role's bits feed
    /// every channel's evaluation at once, so there is no bounded per-channel
    /// audience to compute instead. A receiving client cannot resolve what
    /// changed, only that it should re-ask what it is now allowed to do.
    RoleChanged { role_id: RoleId },
    /// A role was granted to or revoked from a member. Carries both ids,
    /// which leaks nothing beyond `GET /members` already does for any caller:
    /// a member's held role ids are on their public profile. Broadcast rather
    /// than gated on the receiver for the same reason [`Event::MemberRemoved`]
    /// is: the fact itself is not privileged, only a role's bits are, and
    /// those never travel here either.
    MemberRoleChanged { user_id: UserId, role_id: RoleId },
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
        previously_visible_to: Vec<UserId>,
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
    /// An object was placed on a channel's canvas.
    ///
    /// Carries the whole row for the same reason [`Event::MessageCreated`]
    /// does: a brand new object has no prior state to reconcile against, and
    /// an id-only frame would cost every connected viewer one viewport read
    /// per stroke. It is bounded by the write route's props ceiling, which is
    /// sized against [`crate::hub::CHANNEL_CAPACITY`] rather than against any
    /// one drawing.
    ///
    /// Published only for a fresh write. An idempotent replay answers from the
    /// stored row and publishes nothing, so a retry cannot fan a duplicate out.
    /// `object` is `Arc`-wrapped for the same reason [`Event::MessageCreated`]'s are.
    CanvasObjectPlaced {
        channel_id: ChannelId,
        object: Arc<CanvasObject>,
    },
    /// Objects were removed from a channel's canvas.
    ///
    /// Ids only, the shape [`Event::MessageDeleted`] already uses: a removal
    /// publishes an id rather than content, and the actor is deliberately
    /// absent so a moderation act does not name its moderator to the whole
    /// channel. Bounded at [`crate::store::MAX_REMOVE_IDS_PER_OP`], which is
    /// what keeps this inside both the frame ceiling and the hub's ring.
    CanvasObjectsRemoved {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_ids: Vec<CanvasObjectId>,
    },
    /// Every object placed at or below `before_seq` was cleared at once.
    ///
    /// Carries no ids: a clear can cover a channel's whole live ceiling, and
    /// [`crate::hub::CHANNEL_CAPACITY`] buffers 1024 cloned events, so a
    /// 20,000-id frame is exactly what the props ceiling exists to stop one
    /// object doing.
    CanvasCleared {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        before_seq: Seq,
    },
    /// A removal or a clear was undone.
    ///
    /// Ids only, the same shape [`Event::CanvasObjectsRemoved`] already uses -
    /// a receiver that cannot resurrect them locally refetches rather than
    /// being told what to redraw - but only up to
    /// [`crate::store::MAX_REMOVE_IDS_PER_OP`]. A restore of a `remove` is
    /// naturally at or under that bound already; a restore of a `clear` is
    /// not, and can reach the channel's whole live ceiling, exactly the shape
    /// [`Event::CanvasCleared`] carries no ids to avoid. Past the bound this
    /// carries none either, and a receiver falls back to a refetch.
    CanvasObjectsRestored {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_ids: Vec<CanvasObjectId>,
    },
    /// A live pointer position on a channel's canvas, relayed as-is.
    ///
    /// Never persisted and carries no `seq`: unlike every other canvas event
    /// this is not a fact about `canvas_objects` or `canvas_ops`, only a
    /// this-instant hint, so there is nothing for a reconnecting or
    /// newly-arriving client to catch up on and no op-stream slot is spent on
    /// it. A receiver that misses one is not stale, it just has not been told
    /// yet; the sender's next move corrects it. There is no matching "stopped"
    /// event, the deliberate difference from [`Event::TypingStarted`]/
    /// [`Event::TypingStopped`]: a receiver ages a cursor out on its own after
    /// a short silence rather than trusting a stop frame the sender might
    /// never get to send (a closed tab sends nothing further either way).
    CanvasCursorMoved {
        channel_id: ChannelId,
        user_id: UserId,
        x: f64,
        y: f64,
    },
    /// A live in-flight stroke preview on a channel's canvas: the points a
    /// drawer's pen has added since their last preview frame for this
    /// object, relayed as-is.
    ///
    /// The same "never persisted, no seq, no matching catch-up path" shape
    /// [`Event::CanvasCursorMoved`] already uses, extended to carry drawing
    /// content rather than a bare position - and content is exactly why
    /// `Store::timed_out_until` is checked before this publishes, where
    /// [`Event::CanvasCursorMoved`] deliberately is not: a cursor carries no
    /// ink, this does, and a timed-out member may not add to the canvas by
    /// any route, this one included.
    ///
    /// `points` is a delta - only what was added since the sender's last
    /// frame for this `object_id` - never the whole path so far, or relaying
    /// a long stroke would cost every later frame more than the last. A
    /// receiver accumulates them locally, keyed by `object_id`. `ended`
    /// marks the gesture's last frame, whether or not it went on to commit a
    /// real object: a receiver drops the preview the instant it sees this
    /// rather than waiting for staleness to age it out.
    ///
    /// `object_id` never names a row in `canvas_objects`: it is an id the
    /// client mints purely to key this preview session, since the object(s)
    /// a finished stroke actually commits are decided later, by
    /// `POST .../canvas/objects`, and one long stroke can split into several.
    CanvasStrokePreview {
        channel_id: ChannelId,
        user_id: UserId,
        object_id: CanvasObjectId,
        points: Vec<f64>,
        ended: bool,
    },
    /// A placed object was repositioned.
    ///
    /// Carries the whole new box, the same reason [`Event::CanvasObjectPlaced`]
    /// carries the whole row: a receiver needs no refetch to draw it in its
    /// new place. The actor is deliberately absent, the shape
    /// [`Event::CanvasObjectsRemoved`] already uses, since moving another
    /// member's object needs `MANAGE_CANVAS` and so can be a moderation act
    /// the same way a removal is.
    ///
    /// Published only for a fresh, effective move. An idempotent replay, or a
    /// move naming an already-removed object, publishes nothing.
    CanvasObjectMoved {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_id: CanvasObjectId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    /// A placed object's paint order changed.
    ///
    /// Carries the new `z_index` outright, the same reason
    /// [`Event::CanvasObjectMoved`] carries the whole new box: a receiver
    /// needs no refetch to repaint it in its new stacking position. The
    /// actor is deliberately absent, the same shape [`Event::CanvasObjectMoved`]
    /// already uses, since restacking another member's object needs
    /// `MANAGE_CANVAS` and so can be a moderation act the same way a move is.
    ///
    /// Published only for a fresh, effective reorder. An idempotent replay,
    /// or a reorder naming an already-removed object, publishes nothing.
    CanvasObjectReordered {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_id: CanvasObjectId,
        z_index: i64,
    },
    /// A participant's camera or screen-share tile was moved, resized,
    /// locked or sent to the back - decision 0010's reversal, which made
    /// this shared state rather than a per-viewer local one.
    ///
    /// Carries the whole current row, the same reason [`Event::CanvasObjectMoved`]
    /// does: a receiver needs no refetch to redraw the tile. `user_id` names
    /// the participant the tile represents, never who moved it - anyone with
    /// `USE_CANVAS` may rearrange anyone's tile, so there is no moderation
    /// story here for an actor field to serve the way a canvas object's
    /// move or reorder has one.
    ///
    /// Carries no `seq` and is never part of the canvas op stream: a slot
    /// mutates in place rather than appending a history, so there is
    /// nothing here for a reconnecting client to catch up on beyond a
    /// fresh `GET .../canvas/media-slots`.
    CanvasMediaSlotChanged {
        channel_id: ChannelId,
        kind: MediaSlotKind,
        user_id: UserId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        locked: bool,
        sent_to_back: bool,
    },
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
    /// A moderation event with its number, added by [`crate::hub::Hub::publish`]
    /// and never built by a handler. See `hub::moderation_seq`.
    Stamped { seq: u64, event: Box<Event> },
}

impl Event {
    /// The event without any moderation stamp.
    pub fn into_inner(self) -> Event {
        match self {
            Event::Stamped { event, .. } => *event,
            other => other,
        }
    }
}
