// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `call.transcript_mark` frame: a mark or note kept on a running call's
//! transcript, or `mark: null` once it is removed. Gated like a transcript line.

use serde::Serialize;

use crate::http::voice::voice_transcript_marks::MarkDto;
use crate::ids::{CallTranscriptId, CallTranscriptMarkId, ChannelId};
use crate::store::TranscriptMark;

#[derive(Serialize)]
pub(super) struct MarkFrame {
    channel_id: String,
    transcript_id: String,
    mark_id: String,
    mark: Option<MarkDto>,
}

impl MarkFrame {
    pub(super) fn new(
        channel: ChannelId,
        (transcript, mark_id): (CallTranscriptId, CallTranscriptMarkId),
        mark: Option<&TranscriptMark>,
    ) -> Self {
        Self {
            channel_id: channel.to_string(),
            transcript_id: transcript.to_string(),
            mark_id: mark_id.to_string(),
            mark: mark.map(MarkDto::from),
        }
    }
}
