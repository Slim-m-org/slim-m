// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A deleted author stays known to the members who blocked them, and only to
//! them, so a block keeps hiding what that account left behind.

use std::borrow::{Borrow, BorrowMut};
use std::collections::HashMap;

use sqlx::{QueryBuilder, Row, Sqlite};

use crate::ids::{CanvasObjectId, MessageId, UserId};
use crate::store::{CanvasObject, MAX_IDS_PER_QUERY, Message, Store};

/// The read and the id filter for each kept-author table, joined to the viewer's own blocks.
const KEPT_MESSAGE_AUTHORS: (&str, &str) = (
    "SELECT k.message_id AS target, k.author_id AS author FROM blocked_author_messages k \
     JOIN user_blocks b ON b.blocked_id = k.author_id AND b.blocker_id = ",
    " WHERE k.message_id IN (",
);
const KEPT_CANVAS_AUTHORS: (&str, &str) = (
    "SELECT k.object_id AS target, k.author_id AS author FROM blocked_author_canvas_objects k \
     JOIN user_blocks b ON b.blocked_id = k.author_id AND b.blocker_id = ",
    " WHERE k.object_id IN (",
);

impl Store {
    /// Puts back the author of each anonymized message whose deleted author `viewer` blocks.
    pub async fn restore_blocked_message_authors(
        &self,
        viewer: UserId,
        messages: &mut [Message],
    ) -> anyhow::Result<()> {
        let ids: Vec<MessageId> = messages
            .iter()
            .filter(|m| m.author_id.is_none())
            .map(|m| m.id)
            .collect();
        let authors = self
            .blocked_authors(viewer, KEPT_MESSAGE_AUTHORS, &ids)
            .await?;
        for message in messages.iter_mut() {
            if let Some(author) = authors.get(message.id.0.as_bytes().as_slice()) {
                message.author_id = Some(*author);
            }
        }
        Ok(())
    }

    /// [`Self::restore_blocked_message_authors`] for canvas objects.
    pub async fn restore_blocked_canvas_authors<O: BorrowMut<CanvasObject>>(
        &self,
        viewer: UserId,
        objects: &mut [O],
    ) -> anyhow::Result<()> {
        let ids: Vec<CanvasObjectId> = objects
            .iter()
            .map(Borrow::borrow)
            .filter(|o| o.author_id.is_none())
            .map(|o| o.id)
            .collect();
        let authors = self
            .blocked_authors(viewer, KEPT_CANVAS_AUTHORS, &ids)
            .await?;
        for object in objects.iter_mut().map(BorrowMut::borrow_mut) {
            if let Some(author) = authors.get(object.id.0.as_bytes().as_slice()) {
                object.author_id = Some(*author);
            }
        }
        Ok(())
    }

    /// The kept author of each of `ids`, keyed by the id's bytes, for authors `viewer` still blocks.
    async fn blocked_authors<Id>(
        &self,
        viewer: UserId,
        (select, filter): (&'static str, &'static str),
        ids: &[Id],
    ) -> anyhow::Result<HashMap<Vec<u8>, UserId>>
    where
        Id: Copy + for<'q> sqlx::Encode<'q, Sqlite> + sqlx::Type<Sqlite> + Send + 'static,
    {
        let mut found = HashMap::new();
        // Reserve one bind for viewer under the chunk limit; empty makes no chunks.
        for chunk in ids.chunks(MAX_IDS_PER_QUERY - 1) {
            let mut builder = QueryBuilder::new(select);
            builder.push_bind(viewer);
            builder.push(filter);
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(*id);
            }
            builder.push(")");
            for row in builder.build().fetch_all(&self.pool).await? {
                found.insert(row.try_get("target")?, row.try_get("author")?);
            }
        }
        Ok(found)
    }
}

/// Drops what was kept for a deleted author once nobody blocks them any more.
pub(in crate::store) async fn forget_unblocked_author(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    author: UserId,
) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "DELETE FROM blocked_author_messages WHERE author_id = ?
           AND NOT EXISTS (SELECT 1 FROM user_blocks WHERE blocked_id = ?)",
        author,
        author
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM blocked_author_canvas_objects WHERE author_id = ?
           AND NOT EXISTS (SELECT 1 FROM user_blocks WHERE blocked_id = ?)",
        author,
        author
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
