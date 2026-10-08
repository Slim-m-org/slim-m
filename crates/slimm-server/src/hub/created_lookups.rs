// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What every subscriber's `message.created` frame reads from the store,
//! resolved once per published message instead of once per connection.

use std::collections::HashSet;

use tokio::sync::OnceCell;

use crate::ids::{MessageId, UserId};
use crate::store::Store;

/// Shared by every clone of one `Event::MessageCreated`, so the first
/// connection to build a frame pays the two lookups and the rest reuse them.
#[derive(Debug, Default)]
pub struct CreatedLookups(OnceCell<CreatedFacts>);

/// The per-message facts a frame needs: who it mentions, and a webhook post's
/// display label. Both are written with the message, before it is published.
#[derive(Debug)]
pub struct CreatedFacts {
    pub mentioned: HashSet<UserId>,
    pub webhook_username: Option<String>,
}

impl CreatedLookups {
    /// The facts for `message_id`, loading them on first use. A failed load
    /// leaves the cell empty, so the next connection tries again.
    pub async fn get(&self, store: &Store, message_id: MessageId) -> anyhow::Result<&CreatedFacts> {
        self.0
            .get_or_try_init(|| async {
                Ok(CreatedFacts {
                    mentioned: store.mentioned_user_ids(message_id).await?,
                    webhook_username: store.webhook_message_username(message_id).await?,
                })
            })
            .await
    }
}
