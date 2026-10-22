// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which module posted a message, written by the host with the message and never
//! chosen or removable by the module; decision 0023.

use std::collections::HashMap;

use crate::ids::MessageId;
use crate::store::Store;

/// What the host records against a message a module posted.
#[derive(Debug, Clone, Copy)]
pub struct ModuleStamp<'a> {
    pub module_id: &'a str,
    pub module_name: &'a str,
    /// True when no person invoked the run, so the module posted as itself.
    pub background: bool,
}

/// A stored origin, as read back for a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleOrigin {
    pub module_id: String,
    pub module_name: String,
    pub background: bool,
}

impl Store {
    /// The origin of one message, or `None` if no module posted it or it predates the marker. The live
    /// frames read it per message; list and sync use [`Store::module_origins_for_messages`].
    pub async fn module_origin(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Option<ModuleOrigin>> {
        let row = sqlx::query!(
            r#"SELECT module_id, module_name, background AS "background: bool"
               FROM module_message_origins WHERE message_id = ? AND module_name <> ''"#,
            message_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| ModuleOrigin {
            module_id: r.module_id,
            module_name: r.module_name,
            background: r.background,
        }))
    }

    /// The origin of each of `message_ids` a module posted; the rest are absent.
    pub async fn module_origins_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<HashMap<MessageId, ModuleOrigin>> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT message_id, module_id, module_name, background \
             FROM module_message_origins WHERE module_name <> '' AND message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        use sqlx::Row;
        let mut origins = HashMap::new();
        for row in builder.build().fetch_all(&self.pool).await? {
            origins.insert(
                row.try_get("message_id")?,
                ModuleOrigin {
                    module_id: row.try_get("module_id")?,
                    module_name: row.try_get("module_name")?,
                    background: row.try_get("background")?,
                },
            );
        }
        Ok(origins)
    }
}
