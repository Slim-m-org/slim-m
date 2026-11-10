// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The live messages one retention batch should prune, found by one query per
//! reason rather than one query that ORs them all.
//!
//! A single `WHERE gone OR past-window` defeats every range seek, so an idle
//! tick walked the whole live-message index under the write lock whether or
//! not retention was even on. Each query below can stop at its `LIMIT`, and
//! `tests/message_retention_index_plan.rs` plans every one of them.
//!
//! Two reads remain that a `LIMIT` cannot cut short. `messages_channel_live`
//! has no `created_at`, so every pass reads a channel with its own window in
//! full. The Space pass post-filters channels with their own window, so it also
//! walks the old messages of an exempt channel. An index on
//! `messages(channel_id, created_at)` where `deleted_at IS NULL` would end both.
//!
//! `CROSS JOIN` is load-bearing in all three: it pins which table is the
//! outer loop, which a database without `ANALYZE` statistics would otherwise
//! be free to flip into a walk of every message.

use sqlx::SqliteConnection;

use super::message_retention::DAY_MS;
use crate::ids::MessageId;

/// Up to `limit` live messages that retention should prune now, oldest first
/// within what the three sources returned. A source that is off or empty costs
/// one cheap probe, so an idle tick holds the write lock for next to nothing.
pub(super) async fn expired_candidates(
    conn: &mut SqliteConnection,
    space_days: i64,
    now: i64,
    limit: i64,
) -> Result<Vec<MessageId>, sqlx::Error> {
    let mut found = in_gone_channels(conn, limit).await?;
    found.extend(past_channel_window(conn, now, limit).await?);
    if space_days > 0 {
        found.extend(past_space_window(conn, now - space_days * DAY_MS, limit).await?);
    }
    found.sort_unstable_by_key(|(id, created_at)| (*created_at, id.0));
    found.dedup_by_key(|(id, _)| *id);
    found.truncate(limit as usize);
    Ok(found.into_iter().map(|(id, _)| id).collect())
}

/// Whatever is left in a deleted channel or in a thread of one, whatever the window.
async fn in_gone_channels(
    conn: &mut SqliteConnection,
    limit: i64,
) -> Result<Vec<(MessageId, i64)>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT m.id AS "id!: MessageId", m.created_at AS "created_at!: i64"
           FROM channels c
           LEFT JOIN messages pm ON pm.id = c.parent_message_id
           LEFT JOIN channels p ON p.id = pm.channel_id
           CROSS JOIN messages m ON m.channel_id = c.id AND m.deleted_at IS NULL
           WHERE c.deleted_at IS NOT NULL OR p.deleted_at IS NOT NULL
           LIMIT ?"#,
        limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.created_at)).collect())
}

/// Messages past the window of a channel that sets its own, threads following their parent channel.
async fn past_channel_window(
    conn: &mut SqliteConnection,
    now: i64,
    limit: i64,
) -> Result<Vec<(MessageId, i64)>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT m.id AS "id!: MessageId", m.created_at AS "created_at!: i64"
           FROM channels c
           LEFT JOIN messages pm ON pm.id = c.parent_message_id
           JOIN channel_retention cr ON cr.channel_id = COALESCE(pm.channel_id, c.id)
           CROSS JOIN messages m ON m.channel_id = c.id AND m.deleted_at IS NULL
           WHERE cr.retention_days > 0
             AND m.created_at < ?1 - cr.retention_days * ?2
           LIMIT ?3"#,
        now,
        DAY_MS,
        limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.created_at)).collect())
}

/// Messages older than `cutoff` in channels that follow the Space window, oldest first.
async fn past_space_window(
    conn: &mut SqliteConnection,
    cutoff: i64,
    limit: i64,
) -> Result<Vec<(MessageId, i64)>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT m.id AS "id!: MessageId", m.created_at AS "created_at!: i64"
           FROM messages m
           CROSS JOIN channels c ON c.id = m.channel_id
           LEFT JOIN messages pm ON pm.id = c.parent_message_id
           LEFT JOIN channel_retention cr ON cr.channel_id = COALESCE(pm.channel_id, c.id)
           WHERE m.deleted_at IS NULL AND m.created_at < ?1 AND cr.channel_id IS NULL
           ORDER BY m.created_at ASC
           LIMIT ?2"#,
        cutoff,
        limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.created_at)).collect())
}
