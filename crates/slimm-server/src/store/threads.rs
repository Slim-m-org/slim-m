// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Threads: a hidden channel opened from one message, per
//! docs/decisions/0005-threads.md's recommendation. A thread is not its own
//! kind of thing - it is an ordinary row in `channels` with
//! `parent_message_id` set, so every other feature (send, edit, keyset
//! pagination, full-text search, bundled sync, push fan-out, the WebSocket
//! fan-out filter) keeps working unchanged, the same leverage modelling a DM
//! as a channel already bought this codebase once.
//!
//! What is different from a DM: a thread's permissions are never evaluated
//! against itself. [`Store::permission_channel`] (`permissions.rs`) resolves
//! them from the channel its parent message lives in, live, on every check -
//! there is no synthesized overwrite and no copy of the parent's bits to go
//! stale.

use std::collections::HashSet;

use super::{Channel, Store, now_ms};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::notifications::NotificationPreference;

/// How many live threads one channel may have open at once.
///
/// A ceiling at the write, the same shape `MAX_PINS_PER_CHANNEL`
/// (`store/pins.rs`) uses, because a thread is not free the way an ordinary
/// message is: opening one hands it its own full-size canvas and pin budget
/// (`MAX_OBJECTS_PER_CHANNEL`, `MAX_PINS_PER_CHANNEL`), so an unbounded
/// number of threads is an unbounded number of those budgets stacking on one
/// parent channel - see docs/IMPLIED-GAPS.md's "Threads give a free way to
/// multiply two hand-set moderation ceilings". Generous against ordinary use:
/// a channel busy enough to open 500 live side conversations has bigger
/// problems than this ceiling.
pub const MAX_THREADS_PER_CHANNEL: i64 = 500;

/// Why opening a thread failed.
#[derive(Debug)]
pub enum OpenThreadError {
    /// The named message does not exist in this channel, or has been deleted.
    UnknownMessage,
    /// The named message is itself inside a thread. Refused rather than
    /// nested: [`Store::permission_channel`] resolves one hop, from a thread
    /// to the channel its parent message lives in, and stops there - a
    /// second thread layered on top would resolve to the first thread's own
    /// (empty) overwrite bucket instead of the real channel's, silently
    /// dropping whatever deny the real channel had set.
    NestedThread,
    /// The parent channel already holds [`MAX_THREADS_PER_CHANNEL`] live
    /// threads. Only checked when a genuinely new thread would be created -
    /// reopening one that already exists never counts against the ceiling,
    /// the same "idempotent reuse is free" rule `pin_message` applies to a
    /// message already pinned.
    TooMany,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for OpenThreadError {
    fn from(err: sqlx::Error) -> Self {
        OpenThreadError::Internal(err.into())
    }
}

impl From<anyhow::Error> for OpenThreadError {
    fn from(err: anyhow::Error) -> Self {
        OpenThreadError::Internal(err)
    }
}

/// [`Store::open_thread`]'s answer: the channel, and whether this call is
/// what created it. A caller uses `fresh` to decide whether a live
/// "thread opened" notification is warranted - a race loser or a later
/// "reply in thread" on one that already existed must not send a second one.
pub struct OpenedThread {
    pub channel: Channel,
    pub fresh: bool,
}

/// What a live "a reply landed" notification needs, resolved from a thread's
/// own channel id: the real channel to broadcast into, and the message whose
/// reply summary just changed.
pub struct ThreadParent {
    pub parent_channel_id: ChannelId,
    pub parent_message_id: MessageId,
}

impl Store {
    /// Opens the thread hanging off `message_id`, creating it on first use.
    ///
    /// Idempotent and race-safe the way [`Store::open_dm`] is: this reads
    /// whether the message already has a thread before deciding whether to
    /// create one, so it uses [`Store::begin_write`] (`BEGIN IMMEDIATE`)
    /// rather than a plain transaction, and two callers racing the same
    /// message converge on one channel rather than two.
    pub async fn open_thread(
        &self,
        channel_id: ChannelId,
        message_id: MessageId,
    ) -> Result<OpenedThread, OpenThreadError> {
        let mut tx = self.begin_write().await?;

        let row = sqlx::query!(
            r#"SELECT c.parent_message_id AS "parent_message_id: MessageId"
               FROM messages m JOIN channels c ON c.id = m.channel_id
               WHERE m.id = ? AND m.channel_id = ? AND m.deleted_at IS NULL"#,
            message_id,
            channel_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let Some(row) = row else {
            return Err(OpenThreadError::UnknownMessage);
        };
        if row.parent_message_id.is_some() {
            return Err(OpenThreadError::NestedThread);
        }

        if let Some(existing) = sqlx::query_scalar!(
            r#"SELECT id AS "id!: ChannelId" FROM channels
               WHERE parent_message_id = ? AND deleted_at IS NULL"#,
            message_id
        )
        .fetch_optional(&mut *tx)
        .await?
        {
            tx.commit().await?;
            let channel = self
                .channel(existing)
                .await?
                .ok_or_else(|| anyhow::anyhow!("thread channel row exists but is not live"))?;
            return Ok(OpenedThread {
                channel,
                fresh: false,
            });
        }

        // Counted inside the write transaction, or two concurrent opens could both slip past the ceiling.
        let thread_count = sqlx::query_scalar!(
            r#"SELECT COUNT(*) AS "n!: i64" FROM channels c
               JOIN messages pm ON pm.id = c.parent_message_id
               WHERE pm.channel_id = ? AND c.deleted_at IS NULL AND pm.deleted_at IS NULL"#,
            channel_id
        )
        .fetch_one(&mut *tx)
        .await?;
        if thread_count >= MAX_THREADS_PER_CHANNEL {
            return Err(OpenThreadError::TooMany);
        }

        let id = ChannelId::generate();
        let now = now_ms();
        // A thread has no name of its own; a client titles the panel "Thread".
        sqlx::query!(
            "INSERT INTO channels (id, name, kind, parent_message_id, created_at)
             VALUES (?, '', 'text', ?, ?)",
            id,
            message_id,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
             VALUES (?, 'message', 1), (?, 'canvas', 1)",
            id,
            id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;

        Ok(OpenedThread {
            channel: Channel {
                id,
                name: String::new(),
                kind: "text".to_owned(),
                topic: None,
                // Never read: a thread is excluded from every position-ordered query.
                position: 0,
                parent_message_id: Some(message_id),
                // Never read: a thread is excluded from every category grouping.
                category_id: None,
                created_at: now,
                // Never read: a thread has no slow-mode setter of its own.
                slow_mode_seconds: 0,
                join_muted: false,
                default_notification: NotificationPreference::default(),
                room: super::ChannelRoom::default(),
            },
            fresh: true,
        })
    }

    /// Whether `channel_id` is a thread's own channel and, if so, the real
    /// channel its parent message lives in plus the parent message's id.
    ///
    /// Reuses [`Store::permission_channel`]'s own resolution rather than
    /// repeating its join, so a channel this considers a thread is a channel
    /// every permission check already considers one too.
    pub async fn thread_parent(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Option<ThreadParent>> {
        let Some(channel) = self.channel(channel_id).await? else {
            return Ok(None);
        };
        let Some(parent_message_id) = channel.parent_message_id else {
            return Ok(None);
        };
        let Some(parent_channel) = self.permission_channel(channel).await? else {
            return Ok(None);
        };
        Ok(Some(ThreadParent {
            parent_channel_id: parent_channel.id,
            parent_message_id,
        }))
    }

    /// Who has a stake in `thread_channel_id`'s own conversation, derived
    /// entirely from rows that already exist: the parent message's author
    /// (even before anyone has replied, so the very first reply still wakes
    /// somebody) and every distinct author who has ever sent into the
    /// thread's own channel, including one whose only message there was
    /// later deleted - deleting content does not undo having taken part.
    /// This is push's own notion of audience, not a permission: read access
    /// still resolves through [`Store::permission_channel`] exactly as
    /// before, this only ever narrows who is woken among people already
    /// allowed to see the thread.
    pub async fn thread_participants(
        &self,
        thread_channel_id: ChannelId,
        parent_message_id: MessageId,
    ) -> anyhow::Result<HashSet<UserId>> {
        let mut participants = HashSet::new();
        let parent_author: Option<UserId> = sqlx::query_scalar!(
            r#"SELECT author_id AS "author_id: UserId" FROM messages WHERE id = ?"#,
            parent_message_id
        )
        .fetch_optional(&self.pool)
        .await?
        .flatten();
        participants.extend(parent_author);

        let repliers: Vec<UserId> = sqlx::query_scalar!(
            r#"SELECT DISTINCT author_id AS "author_id!: UserId" FROM messages
               WHERE channel_id = ? AND author_id IS NOT NULL"#,
            thread_channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        participants.extend(repliers);

        Ok(participants)
    }

    /// Which of `message_ids` already has a live thread, and how many
    /// undeleted replies are in it - the batch lookup
    /// [`super::super::http::message_enrich`] attaches to each message the
    /// same way it attaches reactions and attachments, one query for the
    /// whole page rather than one per message. A client that was never
    /// online for the thread's creation (or a reply to it) still learns it
    /// exists, and how busy it is, the next time it lists, searches, or
    /// syncs the parent channel, rather than depending on having seen a live
    /// event for either.
    ///
    /// A thread with no replies yet - opened but nothing sent into it -
    /// still appears, with `reply_count` zero and `last_reply_at` `None`;
    /// whether that is worth rendering as an affordance is the caller's
    /// call, not this query's.
    pub async fn thread_summaries_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, ThreadSummary)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }
        // LEFT JOIN, not INNER: a zero-reply thread still produces a row.
        let mut builder = sqlx::QueryBuilder::new(
            "SELECT c.parent_message_id AS parent_message_id, c.id AS thread_channel_id, \
             COUNT(m.id) AS reply_count, MAX(m.created_at) AS last_reply_at \
             FROM channels c \
             LEFT JOIN messages m ON m.channel_id = c.id AND m.deleted_at IS NULL \
             WHERE c.deleted_at IS NULL AND c.parent_message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(") GROUP BY c.parent_message_id, c.id");
        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        rows.into_iter()
            .map(|row| {
                let parent: MessageId = row.try_get("parent_message_id")?;
                let channel_id: ChannelId = row.try_get("thread_channel_id")?;
                let reply_count: i64 = row.try_get("reply_count")?;
                let last_reply_at: Option<i64> = row.try_get("last_reply_at")?;
                Ok((
                    parent,
                    ThreadSummary {
                        channel_id,
                        reply_count,
                        last_reply_at,
                    },
                ))
            })
            .collect()
    }
}

/// A thread's channel id plus how busy it is, batch-loaded onto whichever
/// message opened it - see [`Store::thread_summaries_for_messages`].
pub struct ThreadSummary {
    pub channel_id: ChannelId,
    /// Undeleted messages sent into the thread. Can be zero: opening a
    /// thread creates its channel before anything is sent into it.
    pub reply_count: i64,
    /// When the newest undeleted reply was sent, unix milliseconds. `None`
    /// exactly when `reply_count` is zero.
    pub last_reply_at: Option<i64>,
}
