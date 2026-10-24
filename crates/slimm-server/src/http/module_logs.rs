// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The durable logs behind a module's `log.read`, read from the main database.
//! Like the kv backend, it `block_on`s the async store from the run's blocking thread.
//! Rows are limited to channels the module's principal can view when the read happens.

use std::collections::{HashMap, HashSet};

use tokio::runtime::Handle;

use crate::ids::{ChannelId, UserId};
use crate::module_runtime::{LogBackend, LogError, LogPage, VoiceSessionRow};
use crate::permissions::Permissions;
use crate::store::{Store, VoiceSession};

pub(super) struct SqliteLogs {
    pub(super) store: Store,
    pub(super) handle: Handle,
    /// The module's own principal; without one nothing is visible.
    pub(super) principal: Option<UserId>,
}

impl SqliteLogs {
    /// One permission evaluation per distinct channel.
    async fn visible_channels(
        &self,
        sessions: &[VoiceSession],
    ) -> anyhow::Result<HashMap<ChannelId, bool>> {
        let mut seen = HashMap::new();
        let Some(principal) = self.principal else {
            return Ok(seen);
        };
        let channels: HashSet<ChannelId> = sessions.iter().map(|s| s.channel_id).collect();
        for channel in channels {
            let sees = self
                .store
                .has_permission(principal, channel, Permissions::VIEW_CHANNEL)
                .await?;
            seen.insert(channel, sees);
        }
        Ok(seen)
    }
}

impl LogBackend for SqliteLogs {
    fn voice_sessions(&self, after: i64, limit: i64) -> Result<LogPage, LogError> {
        let (sessions, visible) = self
            .handle
            .block_on(async {
                let sessions = self.store.closed_voice_sessions_after(after, limit).await?;
                let visible = self.visible_channels(&sessions).await?;
                anyhow::Ok((sessions, visible))
            })
            .map_err(|_| LogError)?;
        let next = sessions
            .last()
            .map_or(after, |s| s.closed_seq.unwrap_or(after));
        let rows = sessions
            .into_iter()
            .filter(|s| visible.get(&s.channel_id).copied().unwrap_or(false))
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
            .collect();
        Ok(LogPage { rows, next })
    }
}
