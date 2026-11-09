// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message half of [`crate::hub::Event`], split out so the hub enum stays readable.

use std::sync::Arc;

use crate::components::ComponentRow;
use crate::hub::event_util::{ReactionMoved, Reactors};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::{
    AppSurface, AttachmentSummary, CallRecord, CodeRunSummary, Embed, ForwardSummary, Message, Poll,
};

/// Something that happened to a message; wrapped by [`crate::hub::Event::Message`].
#[derive(Debug, Clone)]
pub enum MessageEvent {
    /// A message was created; carries the full row so a connection can render
    /// the wire frame without another query.
    ///
    /// Attachments ride along because a brand new message can already have
    /// them and the row cannot express them. The sender reads them once for
    /// its own response, so this costs no extra query; leaving them out sent
    /// an image that only appeared on the next sync. `message`, `attachments`
    /// and `forwarded` are `Arc`-wrapped so a `broadcast` fan-out clones a
    /// refcount, not this whole row, for a connection that filters it out.
    Created {
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
        /// Mentions and webhook label, looked up once for every subscriber.
        lookups: Arc<crate::hub::CreatedLookups>,
    },
    /// A message was edited. `op_seq` is its place in the *message-op* stream,
    /// a different sequence from the message's own `seq`, which an edit does
    /// not move; the two sit adjacent in one frame.
    Edited {
        message: Arc<Message>,
        op_seq: i64,
        /// Present when the edited message forwards something. Repeated on an
        /// edit because a frame that omitted it would read as "no longer a forward".
        forwarded: Option<Arc<ForwardSummary>>,
        /// Mentions and webhook label, looked up once for every subscriber.
        lookups: Arc<crate::hub::CreatedLookups>,
    },
    /// A poll's votes changed. Carries the whole per-option tally rather than
    /// a delta, so a client that missed a frame cannot drift, exactly like
    /// `ReactionsChanged`; who cast which vote is deliberately never present.
    PollVoted {
        channel_id: ChannelId,
        message_id: MessageId,
        options: Vec<(i64, i64)>,
        /// The instant-runoff count, on a ranked poll only.
        runoff: Option<crate::store::Runoff>,
    },
    /// A bot replaced or cleared the buttons on its message. Carries the whole
    /// list, like `PollVoted`, so a client that missed a frame cannot drift.
    ComponentsChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        components: Arc<Vec<ComponentRow>>,
    },
    /// A bot replaced or cleared the embeds on its message, by editing it.
    /// The whole list, like `MessageComponentsChanged`.
    EmbedsChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        embeds: Arc<Vec<Embed>>,
    },
    /// The author or a moderator removed a message's link-preview cards. One
    /// way only: a removed preview stays removed. `op_seq` is its place in the
    /// message-op stream, where an offline client finds it as an edit.
    LinkPreviewsRemoved {
        channel_id: ChannelId,
        message_id: MessageId,
        op_seq: i64,
    },
    /// A message was soft-deleted; carries only the ids a live connection
    /// needs to drop it from view, not the content it no longer shows.
    Deleted {
        channel_id: ChannelId,
        message_id: MessageId,
        /// This delete's place in the message-op stream, absent when the
        /// delete found nothing to do.
        op_seq: Option<i64>,
    },
    /// A message's reactions changed. The tally itself stays per viewer, since
    /// a reactor the receiver has blocked is not counted for them, so it is
    /// still derived per receiving connection at send time the way
    /// [`crate::hub::Event::PresenceChanged`]'s status is - `reactors` below only saves
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
        reactors: Arc<Reactors>,
        /// Who moved and which way, for the module event; `None` when the
        /// request changed nothing. Carried rather than diffed from `reactors`,
        /// which cannot say who moved on a message nobody has seen before.
        moved: Option<Arc<ReactionMoved>>,
    },
    /// A fenced code block was run and its shared output changed. Carries the
    /// whole current result (the [`MessageEvent::ThreadUpdated`] shape), overwriting
    /// the one `(message_id, block_index)` row everywhere. Nothing per-viewer,
    /// unlike [`MessageEvent::ReactionsChanged`]: the output is the same for everyone
    /// with VIEW_CHANNEL, so it is delivered as-is. No seq, eventually
    /// consistent; a reconnect refetches via `message_enrich::with_reactions`.
    CodeRunChanged {
        channel_id: ChannelId,
        message_id: MessageId,
        block_index: i64,
        module_id: String,
        command: String,
        ok: bool,
        output: Arc<str>,
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
    /// delta, the "whole current answer" shape [`MessageEvent::PollVoted`] already
    /// uses, so a client that missed a frame cannot drift.
    ///
    /// `channel_id` is the *parent* channel, not the thread's own: that is
    /// the channel a bystander's connection is actually gated on, per
    /// [`crate::store::Store::permission_channel`]'s own resolution, and it
    /// is what lets the ordinary channel-scoped check in `http::ws::authorize`
    /// apply here unchanged rather than needing a thread-aware branch.
    ///
    /// Unlike [`MessageEvent::ReactionsChanged`], the count is carried directly
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
    Pinned {
        channel_id: ChannelId,
        message_id: MessageId,
        /// Null once the pinner's account is anonymized.
        pinned_by: Option<UserId>,
        pinned_at: i64,
    },
    /// A message was unpinned.
    Unpinned {
        channel_id: ChannelId,
        message_id: MessageId,
    },
}
