// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a session looks like to the people in the call: the body of
//! `GET /channels/{id}/voice/call-audio` and of the `voice.call_audio` frame.

use serde::Serialize;

use super::session::{Session, Status, TIME_LIMIT_MS};
use crate::ids::UserId;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CallAudioView {
    pub module_id: String,
    pub module_name: String,
    pub purpose: String,
    pub keeps: String,
    /// `asking` or `on`.
    pub status: &'static str,
    pub asked_by: String,
    /// Everyone who said yes: the only people the module hears.
    pub included: Vec<String>,
    /// Everyone who has not answered yet.
    pub pending: Vec<String>,
    /// When the ask lapses, or the session reaches its time limit.
    pub expires_at_ms: i64,
    /// More people are in the call than a session can ask; later joiners stay out.
    pub full: bool,
}

impl CallAudioView {
    /// Drops everyone whose presence is hidden from `viewer`, except `viewer`,
    /// so a session never names someone the call roster would not.
    pub async fn hide_hidden(
        &mut self,
        store: &crate::store::Store,
        hub: &crate::hub::Hub,
        viewer: UserId,
    ) {
        let me = viewer.to_string();
        let mut hidden = std::collections::HashSet::new();
        for id in self
            .included
            .iter()
            .chain(&self.pending)
            .filter(|id| **id != me)
        {
            let Ok(uuid) = id.parse() else { continue };
            let target = UserId(uuid);
            let visibility = match hub.presence().visibility(target) {
                Some(cached) => Some(cached),
                None => store.presence_visibility(target).await.ok().flatten(),
            };
            if matches!(visibility, Some(crate::presence::Visibility::Hidden)) {
                hidden.insert(id.clone());
            }
        }
        self.included.retain(|id| !hidden.contains(id));
        self.pending.retain(|id| !hidden.contains(id));
    }

    pub fn of(session: &Session) -> Self {
        let ids = |users: Vec<UserId>| users.iter().map(ToString::to_string).collect();
        let (status, expires_at_ms) = match session.status {
            Status::Asking => ("asking", session.expires_at_ms),
            Status::On => (
                "on",
                session.started_at_ms.unwrap_or_default() + TIME_LIMIT_MS,
            ),
        };
        Self {
            module_id: session.subject.module_id.clone(),
            module_name: session.subject.module_name.clone(),
            purpose: session.subject.purpose.clone(),
            keeps: session.subject.keeps.clone(),
            status,
            asked_by: session.requested_by.to_string(),
            included: ids(session.include()),
            pending: ids(session.pending()),
            expires_at_ms,
            full: session.is_full(),
        }
    }
}
