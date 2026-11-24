// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-emoji and per-option rows inside `reactions.changed` and `poll.voted`.

use serde::Serialize;

/// One emoji, how many people this viewer sees using it, and whether this viewer is one of them.
#[derive(Serialize)]
pub(crate) struct ReactionCountDto {
    pub(super) emoji: String,
    pub(super) count: i64,
    pub(super) reacted: bool,
}

/// One poll option and its current public vote count. Never carries who cast
/// a vote, only the option and its tally.
#[derive(Serialize)]
pub(crate) struct PollOptionCountDto {
    pub(super) position: i64,
    pub(super) votes: i64,
}

/// The receiving user's own new vote, present only on a `poll.voted` their own ballot caused.
#[derive(Serialize)]
pub(crate) struct OwnVoteDto {
    pub(super) voted_option: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) voted_ranking: Option<Vec<i64>>,
}
