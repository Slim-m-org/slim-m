// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One counter ordering the canvas state that has no history of its own: object
//! locks and media-slot tiles. Both mutate in place, so a frame that arrives late
//! would otherwise undo a newer one. It is its own stream, never the op `seq`,
//! which has to stay dense.

use sqlx::SqliteConnection;

use crate::ids::ChannelId;
use crate::store::Store;

/// Allocates the next version inside the caller's write transaction.
pub(in crate::store) async fn next_canvas_state_version(
    conn: &mut SqliteConnection,
    channel_id: ChannelId,
) -> Result<i64, sqlx::Error> {
    // Upserted because no channel is created with this stream's row.
    sqlx::query_scalar!(
        r#"INSERT INTO channel_seq_counters (channel_id, stream, next_seq)
           VALUES (?, 'canvas_state', 2)
           ON CONFLICT (channel_id, stream) DO UPDATE SET next_seq = next_seq + 1
           RETURNING next_seq - 1 AS "version!: i64""#,
        channel_id
    )
    .fetch_one(conn)
    .await
}

/// The last version handed out, or 0 before any.
pub(in crate::store) async fn canvas_state_head(
    conn: &mut SqliteConnection,
    channel_id: ChannelId,
) -> Result<i64, sqlx::Error> {
    let next = sqlx::query_scalar!(
        r#"SELECT next_seq AS "next_seq!: i64" FROM channel_seq_counters
           WHERE channel_id = ? AND stream = 'canvas_state'"#,
        channel_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(next.map_or(0, |next| next - 1))
}

impl Store {
    /// A fresh version for a frame that restates current state without changing it.
    pub async fn next_canvas_state_version(&self, channel_id: ChannelId) -> anyhow::Result<i64> {
        let mut tx = self.begin_write().await?;
        let version = next_canvas_state_version(&mut tx, channel_id).await?;
        tx.commit().await?;
        Ok(version)
    }
}
