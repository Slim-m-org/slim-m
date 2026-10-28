// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Request bodies for the message routes (the response DTO lives in `message_dto.rs`).

use serde::Deserialize;

use super::embeds;

#[derive(Deserialize)]
pub(super) struct SendRequest {
    /// Client-generated UUID (v7 preferred) that makes the send idempotent.
    pub(super) id: String,
    pub(super) content: String,
    /// Hex sha256 ids of attachments already uploaded through
    /// `POST /attachments`, in display order. Capped at
    /// [`MAX_ATTACHMENTS_PER_MESSAGE`]; referencing an id that was never
    /// uploaded (or was already swept as an orphan) is a 400, not a silent
    /// drop.
    #[serde(default)]
    pub(super) attachment_ids: Vec<String>,
    /// The subset of `attachment_ids` shown behind a spoiler.
    #[serde(default)]
    pub(super) spoiler_attachment_ids: Vec<String>,
    /// The message this one replies to, if any. Must already exist in this
    /// same channel (live or soft-deleted); anything else is a 400.
    #[serde(default)]
    pub(super) reply_to_id: Option<String>,
    /// On a reply, whether to ping the replied-to author (Discord's "@ On"):
    /// they are added to this message's mentions. Off by default, so a client
    /// that never sends it keeps a reply silent.
    #[serde(default)]
    pub(super) mention_reply: bool,
    /// The message this one forwards, if any. Unlike `reply_to_id` it may
    /// live in any channel the sender can see, and only its id is accepted:
    /// the server reads the original's author, timestamp and text for
    /// itself, so a request cannot dress its own text up as someone else's.
    /// `content` stays the sender's own note alongside the forward, and may
    /// be empty.
    #[serde(default)]
    pub(super) forwarded_from_id: Option<String>,
    /// Structured content, honoured only from a bot; see [`send`].
    #[serde(default)]
    pub(super) embeds: Vec<embeds::RawEmbed>,
    /// Buttons, honoured only from a bot; see decision 0039.
    #[serde(default)]
    pub(super) components: Vec<crate::components::ComponentRow>,
}

#[derive(Deserialize)]
pub(super) struct EditRequest {
    pub(super) content: String,
    /// A replacement for the message's embeds, honoured only from the bot
    /// that wrote it; see [`embeds::honored_for_edit`].
    #[serde(default)]
    pub(super) embeds: Option<Vec<embeds::RawEmbed>>,
}

#[derive(Deserialize)]
pub(super) struct ListParams {
    pub(super) before: Option<i64>,
    pub(super) limit: Option<i64>,
}
