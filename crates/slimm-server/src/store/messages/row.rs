// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message row every message writer creates the same way: probe the id, take the next
//! `seq`, insert, name the author. Each writer then adds its own side-table rows.

use anyhow::Context;
use sqlx::SqliteConnection;

use crate::ids::{ChannelId, MessageId, Seq, UserId};
use crate::store::Message;
use crate::store::message_reads::fetch_message_including_deleted;

pub(in crate::store) struct NewRow<'a> {
    pub channel_id: ChannelId,
    pub author_id: UserId,
    pub id: MessageId,
    pub content: &'a str,
    pub reply_to_id: Option<MessageId>,
    pub now: i64,
}

/// What an earlier write under this id means for a send that reuses it.
pub(in crate::store) enum IdProbe {
    Free,
    Replay(Message),
    Conflict,
}

/// Includes tombstoned rows: the id is unique even after a delete, so a retry must match here, not 500 on INSERT.
pub(in crate::store) async fn probe_id(
    conn: &mut SqliteConnection,
    channel_id: ChannelId,
    author_id: UserId,
    id: MessageId,
) -> anyhow::Result<IdProbe> {
    Ok(
        match fetch_message_including_deleted(&mut *conn, id).await? {
            None => IdProbe::Free,
            Some(existing)
                if existing.channel_id == channel_id && existing.author_id == Some(author_id) =>
            {
                IdProbe::Replay(existing)
            }
            Some(_) => IdProbe::Conflict,
        },
    )
}

/// Allocates the channel's next message `seq`, inserts the row and returns the message as stored.
pub(in crate::store) async fn insert_message_row(
    conn: &mut SqliteConnection,
    row: &NewRow<'_>,
) -> anyhow::Result<Message> {
    // RETURNING sees the updated row, so `next_seq - 1` is this message's seq.
    let seq = sqlx::query_scalar!(
        r#"UPDATE channel_seq_counters SET next_seq = next_seq + 1
           WHERE channel_id = ? AND stream = 'message'
           RETURNING next_seq - 1 AS "seq!: i64""#,
        row.channel_id
    )
    .fetch_optional(&mut *conn)
    .await?
    .context("channel has no message sequence counter")?;

    sqlx::query!(
        r#"INSERT INTO messages (id, channel_id, author_id, seq, content, created_at, reply_to_id)
           VALUES (?, ?, ?, ?, ?, ?, ?)"#,
        row.id,
        row.channel_id,
        row.author_id,
        seq,
        row.content,
        row.now,
        row.reply_to_id
    )
    .execute(&mut *conn)
    .await?;

    // Read in the insert's transaction so the echoed message matches a later fetch.
    let author_display_name = sqlx::query_scalar!(
        r#"SELECT display_name AS "display_name!: String"
           FROM users WHERE id = ? AND deleted_at IS NULL"#,
        row.author_id
    )
    .fetch_optional(&mut *conn)
    .await?;

    Ok(Message {
        id: row.id,
        channel_id: row.channel_id,
        author_id: Some(row.author_id),
        author_display_name,
        seq: Seq(seq),
        content: row.content.to_owned(),
        created_at: row.now,
        edited_at: None,
        reply_to_id: row.reply_to_id,
    })
}
