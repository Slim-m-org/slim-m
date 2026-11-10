// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The payload of [`super::Event::PresenceChanged`]: who changed, and the one store read their fan-out shares.

use std::sync::Arc;

use tokio::sync::OnceCell;

use crate::ids::UserId;
use crate::presence::Visibility;
use crate::store::Store;

/// Shared by every clone of one published change, so the first connection to miss the presence
/// cache pays the lookup and the rest reuse it. A last disconnect always misses it.
#[derive(Debug, Clone)]
pub struct PresenceChange {
    pub user_id: UserId,
    stored_visibility: Arc<OnceCell<Option<Visibility>>>,
}

impl PresenceChange {
    pub fn of(user_id: UserId) -> Self {
        Self {
            user_id,
            stored_visibility: Arc::default(),
        }
    }

    /// The user's stored visibility, read on first use; `None` when the account is gone.
    /// A failed read leaves the cell empty, so the next connection tries again.
    pub async fn stored_visibility(&self, store: &Store) -> anyhow::Result<Option<Visibility>> {
        self.stored_visibility
            .get_or_try_init(|| store.presence_visibility(self.user_id))
            .await
            .copied()
    }
}
