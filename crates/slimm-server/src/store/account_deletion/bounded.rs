// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The parts of a deletion that grow with how long the account was used, each
//! cleared a bounded batch at a time so no one transaction holds the writer for
//! the whole account.

use std::collections::BTreeSet;

use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::Store;

/// What clearing an account changed that other people's open views still show.
#[derive(Debug, Default)]
pub(super) struct Cleared {
    pub reactions_changed: Vec<(ChannelId, MessageId)>,
    pub polls_changed: Vec<(ChannelId, MessageId)>,
    pub rooms_renamed: Vec<ChannelId>,
}

/// Runs one batched statement in its own write transaction until a batch comes back empty.
macro_rules! drain {
    ($store:expr, rows: $query:expr) => {{
        loop {
            let mut tx = $store.begin_write().await?;
            let touched = $query.execute(&mut *tx).await?.rows_affected();
            tx.commit().await?;
            if touched == 0 {
                break;
            }
        }
    }};
    ($store:expr, returning: $query:expr) => {{
        let mut returned = Vec::new();
        loop {
            let mut tx = $store.begin_write().await?;
            let batch = $query.fetch_all(&mut *tx).await?;
            tx.commit().await?;
            if batch.is_empty() {
                break;
            }
            returned.extend(batch);
        }
        returned
    }};
}

/// Clears `user_id` from everything they authored or took part in that can run
/// to many rows. Idempotent: each statement only matches rows not yet cleared.
pub(super) async fn clear_authored_content(
    store: &Store,
    user_id: UserId,
) -> anyhow::Result<Cleared> {
    clear_message_authorship(store, user_id).await?;
    clear_canvas_authorship(store, user_id).await?;
    // A forward's snapshot stays visible to whoever it reached, so its author id goes the way a message's does.
    drain!(store, rows: sqlx::query!(
        "UPDATE message_forwards SET origin_author_id = NULL WHERE rowid IN
           (SELECT rowid FROM message_forwards WHERE origin_author_id = ? LIMIT 500)",
        user_id
    ));
    drain!(store, rows: sqlx::query!(
        "UPDATE message_ops SET actor_id = NULL WHERE (channel_id, seq) IN
           (SELECT channel_id, seq FROM message_ops WHERE actor_id = ? LIMIT 500)",
        user_id
    ));
    drain!(store, rows: sqlx::query!(
        "UPDATE canvas_ops SET actor_id = NULL WHERE (channel_id, seq) IN
           (SELECT channel_id, seq FROM canvas_ops WHERE actor_id = ? LIMIT 500)",
        user_id
    ));
    let reacted = drain!(store, returning: sqlx::query!(
        r#"DELETE FROM reactions WHERE user_id = ? AND (message_id, emoji) IN
             (SELECT message_id, emoji FROM reactions WHERE user_id = ? LIMIT 500)
           RETURNING (SELECT channel_id FROM messages WHERE id = message_id) AS "channel_id?: ChannelId",
                     message_id AS "message_id!: MessageId""#,
        user_id,
        user_id
    ));
    // How somebody voted is theirs, like the emoji they reacted with; the tally moves as a reaction count would.
    let voted = drain!(store, returning: sqlx::query!(
        r#"DELETE FROM poll_votes WHERE user_id = ? AND message_id IN
             (SELECT message_id FROM poll_votes WHERE user_id = ? LIMIT 500)
           RETURNING (SELECT channel_id FROM messages WHERE id = message_id) AS "channel_id?: ChannelId",
                     message_id AS "message_id!: MessageId""#,
        user_id,
        user_id
    ));
    // A mention marker names the account it was mentioning, not the message's own content - nothing left to anonymize.
    drain!(store, rows: sqlx::query!(
        "DELETE FROM message_mentions WHERE user_id = ? AND message_id IN
           (SELECT message_id FROM message_mentions WHERE user_id = ? LIMIT 500)",
        user_id,
        user_id
    ));
    // Who was on which call, and when, is this person's own presence history (decision 0066).
    drain!(store, rows: sqlx::query!(
        "DELETE FROM voice_call_events WHERE rowid IN
           (SELECT rowid FROM voice_call_events WHERE user_id = ? LIMIT 500)",
        user_id
    ));
    // What someone said on a call is theirs; the rest of each transcript stays readable.
    drain!(store, rows: sqlx::query!(
        "DELETE FROM call_transcript_lines WHERE id IN
           (SELECT id FROM call_transcript_lines WHERE speaker_id = ? LIMIT 500)",
        user_id
    ));
    drain!(store, rows: sqlx::query!(
        "DELETE FROM attachment_uploaders WHERE uploaded_by = ? AND sha256 IN
           (SELECT sha256 FROM attachment_uploaders WHERE uploaded_by = ? LIMIT 500)",
        user_id,
        user_id
    ));
    Ok(Cleared {
        reactions_changed: distinct(reacted.into_iter().map(|r| (r.channel_id, r.message_id))),
        polls_changed: distinct(voted.into_iter().map(|r| (r.channel_id, r.message_id))),
        rooms_renamed: Vec::new(),
    })
}

/// Each message once; a row whose message is already gone has nothing left to announce.
fn distinct(
    pairs: impl Iterator<Item = (Option<ChannelId>, MessageId)>,
) -> Vec<(ChannelId, MessageId)> {
    pairs
        .filter_map(|(channel_id, message_id)| Some((channel_id?, message_id)))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Nulls the author of `user_id`'s messages, first recording each one for any
/// member who blocked them, so the block keeps hiding it.
async fn clear_message_authorship(store: &Store, user_id: UserId) -> anyhow::Result<()> {
    loop {
        let mut tx = store.begin_write().await?;
        sqlx::query!(
            "INSERT OR IGNORE INTO blocked_author_messages (message_id, author_id)
             SELECT id, author_id FROM messages
             WHERE author_id = ? AND EXISTS (SELECT 1 FROM user_blocks WHERE blocked_id = ?)
             ORDER BY fts_rowid LIMIT 500",
            user_id,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        let touched = sqlx::query!(
            "UPDATE messages SET author_id = NULL WHERE fts_rowid IN
               (SELECT fts_rowid FROM messages WHERE author_id = ? ORDER BY fts_rowid LIMIT 500)",
            user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        if touched == 0 {
            return Ok(());
        }
    }
}

/// [`clear_message_authorship`] for canvas objects.
async fn clear_canvas_authorship(store: &Store, user_id: UserId) -> anyhow::Result<()> {
    loop {
        let mut tx = store.begin_write().await?;
        sqlx::query!(
            "INSERT OR IGNORE INTO blocked_author_canvas_objects (object_id, author_id)
             SELECT id, author_id FROM canvas_objects
             WHERE author_id = ? AND EXISTS (SELECT 1 FROM user_blocks WHERE blocked_id = ?)
             ORDER BY rt_id LIMIT 500",
            user_id,
            user_id
        )
        .execute(&mut *tx)
        .await?;
        let touched = sqlx::query!(
            "UPDATE canvas_objects SET author_id = NULL WHERE rt_id IN
               (SELECT rt_id FROM canvas_objects WHERE author_id = ? ORDER BY rt_id LIMIT 500)",
            user_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        if touched == 0 {
            return Ok(());
        }
    }
}
