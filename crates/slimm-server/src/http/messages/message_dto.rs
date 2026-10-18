// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wire shape a message answers with, split out of [`super`]
//! when that file crossed the 500-line hard ceiling again (it had already
//! been split once, for [`super::message_enrich`]). This is the type only;
//! every route that builds or enriches one still lives in `messages.rs` and
//! `message_enrich.rs`.

use serde::Serialize;

use super::super::apps::AppSurfaceDto;
use super::super::embeds::EmbedDto;
use super::super::polls::PollDto;
use super::message_forwards::ForwardedDto;
use crate::store::{AttachmentSummary, CallRecord as StoreCallRecord, Message, MessageRevision};

#[derive(Serialize)]
pub(crate) struct MessageDto {
    id: String,
    channel_id: String,
    author_id: Option<String>,
    /// Null once the author's account is anonymized, which is also when
    /// `author_id` goes null. Clients render their own fallback rather than
    /// being handed a server-invented placeholder.
    author_display_name: Option<String>,
    seq: i64,
    content: String,
    created_at: i64,
    edited_at: Option<i64>,
    /// The message this one replies to, or `null`. Only ever the id: the
    /// parent's own content, author and liveness are resolved by looking that
    /// id up like any other message, never copied onto this row, or a client
    /// caching this reply would go stale the moment the parent is edited or
    /// deleted with no way to notice.
    reply_to_id: Option<String>,
    /// The thread opened from this message, or `null` if none has been
    /// started yet. Always present as a key, the same "always there, empty
    /// or null means genuinely none" convention `poll` and `reactions`
    /// follow. Set by [`super::message_enrich::with_reactions`]'s batch
    /// lookup, never by this conversion: a message can only grow a thread
    /// after it already exists, so a freshly sent or edited one always
    /// carries `null` here, exactly like a fresh message's `poll`.
    pub(crate) thread_channel_id: Option<String>,
    /// Undeleted replies in this message's thread, or `null` if no thread
    /// has been started - same convention as `thread_channel_id`, and
    /// `null` whenever that field is `null`. Can be `0`: opening a thread
    /// creates its channel before the first reply lands in it. Batch-loaded
    /// alongside `thread_channel_id` by
    /// [`super::message_enrich::with_reactions`], never carried on `Message`
    /// itself.
    pub(crate) thread_reply_count: Option<i64>,
    /// When the thread's newest undeleted reply was sent, unix milliseconds,
    /// or `null` when `thread_reply_count` is `null` or `0`. Lets a client
    /// show "3 replies, last one yesterday" rather than just a count.
    pub(crate) thread_last_reply_at: Option<i64>,
    /// How many of the thread's live messages the caller has not yet read,
    /// or `null` when `thread_channel_id` is `null` - same convention as the
    /// other three thread fields. Genuinely `0` for a thread the caller has
    /// fully read, never omitted the way an unstarted thread's fields are.
    /// Batch-loaded alongside `thread_channel_id` by
    /// [`super::message_enrich::with_reactions`], from
    /// [`crate::store::Store::thread_unread_counts`] - the read-tracking
    /// every channel already has, surfaced here for the first time.
    pub(crate) thread_unread_count: Option<i64>,
    /// What this message forwards, or `null` when it forwards nothing.
    /// Always present as a key, the same convention `poll` follows. Set by
    /// [`super::message_forwards::for_messages`] and by the send route,
    /// never by this conversion, which has nowhere to read an origin from.
    ///
    /// A forwarding message's own `content` is whatever the forwarder chose
    /// to say alongside it, and is empty when they said nothing. The thing
    /// being forwarded is in here and never mixed into that text.
    pub(crate) forwarded: Option<ForwardedDto>,
    /// Empty unless the caller asked for a list, which is the only path that
    /// batch-loads them; a single echoed message carries none because it
    /// cannot have any yet.
    #[serde(default)]
    pub(crate) reactions: Vec<ReactionDto>,
    /// The poll this message carries, if any. Always present as a key (never
    /// omitted): `null` means this message is not a poll, the same "always
    /// there, empty or null means genuinely none" convention `reactions`
    /// already follows. Set by [`super::super::polls::attach_polls`], not by this
    /// conversion, since a bare `Message` has nowhere to read poll data from.
    pub(crate) poll: Option<PollDto>,
    /// The app this message launches, if any. Always present as a key: `null`
    /// means this message launches no app - the same "always there, null means
    /// genuinely none" convention `poll` follows. Set by
    /// [`super::super::apps::attach_app_surfaces`], not by this conversion, since a
    /// bare `Message` has nowhere to read it from. The surface's live, shared
    /// state is not here: it rides `code_runs` at block 0, like a run block.
    pub(crate) app_surface: Option<AppSurfaceDto>,
    /// Always present, empty when there are none - same convention as
    /// `reactions`. Unlike reactions and polls, a fresh send can carry these
    /// immediately (they are uploaded before the send, then referenced in
    /// it), so the send path reads them once and fills this in on both its
    /// own response and the live frame, rather than leaving it empty the way
    /// `reactions` is left empty for a message that cannot have any yet.
    #[serde(default)]
    pub(crate) attachments: Vec<AttachmentDto>,
    /// The shared result of each fenced code block that has been run in this
    /// message, empty when none have. Always present, empty means none - the
    /// same convention as `reactions`. Set by
    /// [`super::message_enrich::with_reactions`]'s batch lookup, never by this
    /// conversion: a freshly sent message carries none because nobody has run
    /// a block in it yet, exactly like `reactions`.
    #[serde(default)]
    pub(crate) code_runs: Vec<CodeRunDto>,
    /// The call this message records, if any. Always present as a key: `null`
    /// means this message is not a call, the same "always there, null means
    /// genuinely none" convention `poll` follows. Set by
    /// [`super::message_enrich::with_reactions`]'s batch lookup, never by this
    /// conversion, since a bare `Message` has nowhere to read it from.
    ///
    /// A call message's `content` is always empty. What to say about a call
    /// depends on which side is reading it - "missed call" and "you called, no
    /// answer" are one row - so the wording is the client's.
    pub(crate) call: Option<CallDto>,
    /// Whether this message mentions the caller - by `@name`, by a
    /// `@[Role]` the caller holds, or by `@everyone`/`@here` when the author
    /// held `MENTION_EVERYONE` - per-viewer exactly like `reacted`, and
    /// resolved the same way: `false` by default on this bare conversion,
    /// overwritten by `store::mentioned_messages_for` wherever a page of
    /// messages is enriched (`http::message_enrich::with_reactions`) and by
    /// `store::is_mentioned` on the live `message.created`/`message.edited`
    /// frames. Always `false` on a caller's own send or edit response: the
    /// resolver that fills this in never mentions its own author.
    pub(crate) mentions_me: bool,
    /// Structured content attached by a webhook or a bot; see decision 0030.
    /// Fixed once a message exists, like `attachments`.
    #[serde(default)]
    pub(crate) embeds: Vec<EmbedDto>,
    /// A webhook post's own `username` label, `null` for every other message.
    /// A label only: `author_display_name` stays the webhook's name, and the
    /// client keeps the webhook badge beside it. Set by the read enrichment
    /// and the live frames, never by this conversion.
    pub(crate) webhook_username: Option<String>,
    /// Buttons a bot attached; see decision 0039. A bot may replace them.
    #[serde(default)]
    pub(crate) components: Vec<crate::components::ComponentRow>,
}

/// One attachment as it appears on a message.
#[derive(Serialize, Clone)]
pub(crate) struct AttachmentDto {
    id: String,
    filename: String,
    content_type: String,
    size: i64,
    /// Shown behind a spoiler on this message; omitted when false.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    spoiler: bool,
    /// The uploaded original kept beside this copy; omitted when none was kept.
    #[serde(skip_serializing_if = "Option::is_none")]
    original: Option<OriginalDto>,
}

#[derive(Serialize, Clone)]
pub(crate) struct OriginalDto {
    size: i64,
    filename: String,
}

impl From<AttachmentSummary> for AttachmentDto {
    fn from(a: AttachmentSummary) -> Self {
        Self {
            id: a.id,
            filename: a.filename,
            content_type: a.content_type,
            size: a.size,
            spoiler: a.spoiler,
            original: a.original.map(|o| OriginalDto {
                size: o.size,
                filename: o.filename,
            }),
        }
    }
}

/// How a DM call ended, as it rides the message that records it.
///
/// `duration_ms` is null for every outcome but `answered`, and the outcome
/// strings are the text form of `voice::CallRingOutcome`.
#[derive(Serialize, Clone)]
pub(crate) struct CallDto {
    pub(crate) caller_id: Option<String>,
    pub(crate) outcome: String,
    pub(crate) duration_ms: Option<i64>,
}

impl From<StoreCallRecord> for CallDto {
    fn from(record: StoreCallRecord) -> Self {
        Self {
            caller_id: record.caller_id.map(|id| id.to_string()),
            outcome: record.outcome,
            duration_ms: record.duration_ms,
        }
    }
}

/// One emoji on a message, with the asking user's own state.
#[derive(Serialize)]
pub(crate) struct ReactionDto {
    pub(crate) emoji: String,
    pub(crate) count: i64,
    /// Whether the caller reacted with this emoji, so the client can render the
    /// toggled state without a second request.
    pub(crate) reacted: bool,
}

/// One fenced code block's shared run result. `output` holds the module's
/// output when `ok`, or its error message when not - the same `{ok, output}`
/// / `{ok, error}` shape the run route answers with, flattened to one field
/// since a stored row is always one or the other.
#[derive(Serialize)]
pub(crate) struct CodeRunDto {
    pub(crate) block_index: i64,
    pub(crate) module_id: String,
    pub(crate) command: String,
    pub(crate) ok: bool,
    pub(crate) output: String,
    /// Who ran it, or `null` once their account is anonymized.
    pub(crate) ran_by: Option<String>,
    pub(crate) ran_at: i64,
}

impl MessageDto {
    /// Roughly what this row costs a `/sync` response, for the shared byte
    /// budget - content plus every embed's own text.
    pub(in crate::http) fn wire_cost(&self) -> usize {
        let embeds: usize = self
            .embeds
            .iter()
            .map(|e| {
                e.title.as_deref().map_or(0, str::len)
                    + e.description.as_deref().map_or(0, str::len)
                    + e.author_name.as_deref().map_or(0, str::len)
                    + e.footer_text.as_deref().map_or(0, str::len)
                    + e.fields
                        .iter()
                        .map(|f| f.name.len() + f.value.len())
                        .sum::<usize>()
            })
            .sum();
        self.content.len() + embeds + 128
    }
}

impl From<Message> for MessageDto {
    fn from(message: Message) -> Self {
        Self {
            id: message.id.to_string(),
            channel_id: message.channel_id.to_string(),
            author_id: message.author_id.map(|id| id.to_string()),
            author_display_name: message.author_display_name,
            seq: message.seq.0,
            content: message.content,
            created_at: message.created_at,
            edited_at: message.edited_at,
            reply_to_id: message.reply_to_id.map(|id| id.to_string()),
            thread_channel_id: None,
            thread_reply_count: None,
            thread_last_reply_at: None,
            thread_unread_count: None,
            forwarded: None,
            reactions: Vec::new(),
            poll: None,
            app_surface: None,
            call: None,
            attachments: Vec::new(),
            code_runs: Vec::new(),
            mentions_me: false,
            embeds: Vec::new(),
            webhook_username: None,
            components: Vec::new(),
        }
    }
}

/// One version a message has held, for the edit-history read. `at` is when
/// this version became the message's content; the list is oldest first and
/// its last element is the current content.
#[derive(Serialize)]
pub(crate) struct MessageRevisionDto {
    content: String,
    at: i64,
}

impl From<MessageRevision> for MessageRevisionDto {
    fn from(revision: MessageRevision) -> Self {
        Self {
            content: revision.content,
            at: revision.at,
        }
    }
}
