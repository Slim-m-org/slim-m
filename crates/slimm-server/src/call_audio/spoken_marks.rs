// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Acting on a spoken mark: the runtime loop hands each kept line here, and a
//! session that started with spoken marks on turns "hey space, mark that" into
//! a mark by the speaker at the line's time. The only wait it adds to the loop
//! is the one insert when a command fires.

use super::AcceptedSegment;
use super::commands::{Listening, Parsed, WakePhrase};
use super::marks;
use crate::http::AppState;
use crate::ids::{CallTranscriptId, CallTranscriptMarkId};
use crate::store::{MarkKind, MarkSource, NewMark, now_ms};

/// The runtime task's own state: who said the phrase, and the Space's switch as last read.
#[derive(Debug, Default)]
pub struct Ears {
    listening: Listening,
    phrase: Option<WakePhrase>,
}

impl Ears {
    /// Re-reads the switch and the phrase, so turning it off takes effect within one standing check.
    pub async fn refresh(&mut self, state: &AppState) {
        match state.store.voice_commands().await {
            Ok(commands) => {
                self.phrase = commands
                    .on
                    .then(|| WakePhrase::parse(&commands.phrase).ok())
                    .flatten();
            }
            Err(err) => tracing::warn!(%err, "could not read voice commands"),
        }
        self.listening.prune(now_ms());
    }

    pub async fn heard(&mut self, state: &AppState, segment: &AcceptedSegment) {
        let Some(phrase) = &self.phrase else {
            return;
        };
        if segment.listens_for.is_none() {
            return;
        }
        let who = (segment.session_id, segment.user_id);
        let (kind, text) = match self
            .listening
            .hear(who, segment.start_ms, &segment.text, phrase)
        {
            Parsed::Mark => (MarkKind::Mark, None),
            Parsed::Note(text) => (MarkKind::Note, Some(text)),
            Parsed::None | Parsed::Wake => return,
        };
        let new = NewMark {
            id: CallTranscriptMarkId::generate(),
            transcript_id: CallTranscriptId(segment.session_id),
            author: segment.user_id,
            at: segment.start_ms,
            kind,
            text: text.as_deref(),
            source: MarkSource::Voice,
            gap_ms: 0,
        };
        if let Err(err) = marks::add_spoken(state, segment.channel, &new).await {
            tracing::warn!(%err, "could not keep a spoken mark");
        }
    }
}
