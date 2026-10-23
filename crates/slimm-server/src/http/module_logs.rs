// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The durable logs behind a module's `log.read`, read from the main database.
//! Like the kv backend, it `block_on`s the async store from the run's blocking thread.

use tokio::runtime::Handle;

use crate::module_runtime::{LogBackend, LogError, VoiceSessionRow};
use crate::store::Store;

pub(super) struct SqliteLogs {
    pub(super) store: Store,
    pub(super) handle: Handle,
}

impl LogBackend for SqliteLogs {
    fn voice_sessions(&self, after: i64, limit: i64) -> Result<Vec<VoiceSessionRow>, LogError> {
        let sessions = self
            .handle
            .block_on(self.store.closed_voice_sessions_after(after, limit))
            .map_err(|_| LogError)?;
        Ok(sessions
            .into_iter()
            .filter_map(|s| {
                Some(VoiceSessionRow {
                    id: s.id,
                    user_id: s.user_id.to_string(),
                    channel_id: s.channel_id.to_string(),
                    joined_at_ms: s.joined_at,
                    left_at_ms: s.left_at?,
                    alone_ms: s.alone_ms,
                })
            })
            .collect())
    }
}
