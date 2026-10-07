// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! App surfaces: a message that launches an installed module's `app` extension
//! point, rendered inline as an interactive shared surface rather than as text.
//!
//! Creating one is creating a message, so [`Store::send_app_message`] mirrors
//! [`super::polls::Store::send_poll_message`] closely: the same idempotent-by-id
//! scoping and per-channel `seq` allocation in the same transaction as the
//! insert, just with the `(module_id, command)` this surface launches inserted
//! alongside. An app surface never outlives or moves between messages, so it is
//! keyed by `message_id` rather than a surrogate id of its own.
//!
//! The surface's live, shared state is not stored here: it is the module's own
//! output, recorded and broadcast through `code_runs` at block 0 exactly like a
//! run fenced code block (see [`super::code_runs`]), so slim keeps no notion of
//! what any app does.

use sqlx::QueryBuilder;

use super::messages::row::{IdProbe, NewRow, insert_message_row, probe_id};
use super::{Sent, Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};

/// An app surface attached to a message: which installed module's command this
/// message launches. The rendered, shared state lives in `code_runs`, not here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppSurface {
    pub module_id: String,
    pub command: String,
    pub created_by: Option<UserId>,
    pub created_at: i64,
}

/// Why creating an app-surface message failed.
#[derive(Debug)]
pub enum CreateAppSurfaceError {
    /// A message with this id already exists for a different channel or author.
    /// Mirrors `CreatePollError::IdConflict`: a reused id must never return a
    /// foreign message.
    IdConflict,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for CreateAppSurfaceError {
    fn from(err: sqlx::Error) -> Self {
        CreateAppSurfaceError::Internal(err.into())
    }
}

impl From<anyhow::Error> for CreateAppSurfaceError {
    fn from(err: anyhow::Error) -> Self {
        CreateAppSurfaceError::Internal(err)
    }
}

impl Store {
    /// Sends a message that launches `module_id`'s `command`. Idempotent by
    /// `id` within its `(channel, author)` scope, exactly like
    /// [`super::messages::Store::send_message`].
    pub async fn send_app_message(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
        id: MessageId,
        content: &str,
        module_id: &str,
        command: &str,
    ) -> Result<Sent, CreateAppSurfaceError> {
        let now = now_ms();
        // Reads the message before deciding what to write; see Store::begin_write.
        let mut tx = self.begin_write().await?;

        match probe_id(&mut tx, channel_id, author_id, id).await? {
            IdProbe::Free => {}
            IdProbe::Replay(message) => {
                tx.commit().await?;
                return Ok(Sent {
                    message,
                    fresh: false,
                });
            }
            IdProbe::Conflict => {
                tx.commit().await?;
                return Err(CreateAppSurfaceError::IdConflict);
            }
        }

        let message = insert_message_row(
            &mut tx,
            &NewRow {
                channel_id,
                author_id,
                id,
                content,
                reply_to_id: None,
                now,
            },
        )
        .await?;

        sqlx::query!(
            r#"INSERT INTO app_surfaces (message_id, channel_id, module_id, command, created_by, created_at)
               VALUES (?, ?, ?, ?, ?, ?)"#,
            id,
            channel_id,
            module_id,
            command,
            author_id,
            now
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(Sent {
            message,
            fresh: true,
        })
    }

    /// A single message's app surface, or `None` if it carries none.
    pub async fn app_surface_for_message(
        &self,
        message_id: MessageId,
    ) -> anyhow::Result<Option<AppSurface>> {
        Ok(self
            .app_surfaces_for_messages(&[message_id])
            .await?
            .into_iter()
            .next()
            .map(|(_, surface)| surface))
    }

    /// App surfaces for a page of messages in one query, the same batch-enrich
    /// shape reactions and code runs use - a query per row would be a query per
    /// message. Only messages that actually carry a surface appear.
    pub async fn app_surfaces_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, AppSurface)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }
        use sqlx::Row;

        let mut builder = QueryBuilder::new(
            "SELECT message_id, module_id, command, created_by, created_at \
             FROM app_surfaces WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(")");
        let rows = builder.build().fetch_all(&self.pool).await?;

        rows.into_iter()
            .map(|row| {
                let message_id: MessageId = row.try_get("message_id")?;
                Ok((
                    message_id,
                    AppSurface {
                        module_id: row.try_get("module_id")?,
                        command: row.try_get("command")?,
                        created_by: row.try_get("created_by")?,
                        created_at: row.try_get("created_at")?,
                    },
                ))
            })
            .collect()
    }
}
