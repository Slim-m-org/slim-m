// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whole-object reads that are not a spatial region: some objects by id, and the board's count and extent.

use super::{CanvasObject, Rect, Store, latest_canvas_seq_query};
use crate::ids::{CanvasObjectId, ChannelId, Seq, UserId};

/// How many live objects a board holds and the box around all of them.
#[derive(Debug, Clone, Copy)]
pub struct CanvasSummary {
    pub count: i64,
    /// Absent for an empty board.
    pub bounds: Option<Rect>,
    pub latest_seq: i64,
}

impl Store {
    /// The live objects among `ids` in this channel, in paint order, with the canvas head read in the same snapshot.
    ///
    /// Ids that are unknown, removed or another channel's are simply absent.
    pub async fn canvas_objects_by_ids(
        &self,
        channel_id: ChannelId,
        ids: &[CanvasObjectId],
    ) -> anyhow::Result<(i64, Vec<CanvasObject>)> {
        let mut tx = self.begin_read().await?;
        let latest_seq = latest_canvas_seq_query(&mut *tx, channel_id).await?;
        let mut objects = Vec::with_capacity(ids.len());
        for id in ids {
            let row = sqlx::query_as!(
                CanvasObject,
                r#"SELECT o.id AS "id!: CanvasObjectId", o.kind AS "kind!",
                          o.z_index AS "z_index!: i64",
                          o.x AS "x!: f64", o.y AS "y!: f64",
                          o.w AS "w!: f64", o.h AS "h!: f64",
                          p.props AS "props!", o.author_id AS "author_id: UserId",
                          o.seq AS "seq!: Seq", o.created_at AS "created_at!: i64"
                   FROM canvas_objects o
                   JOIN canvas_object_props p ON p.object_id = o.id
                   WHERE o.id = ? AND o.channel_id = ? AND o.deleted_at IS NULL"#,
                id,
                channel_id
            )
            .fetch_optional(&mut *tx)
            .await?;
            objects.extend(row);
        }
        tx.commit().await?;
        objects.sort_by_key(|o| (o.z_index, o.seq.0));
        Ok((latest_seq, objects))
    }

    /// The channel's live object count and bounding box, with the canvas head read in the same snapshot.
    pub async fn canvas_summary(&self, channel_id: ChannelId) -> anyhow::Result<CanvasSummary> {
        let mut tx = self.begin_read().await?;
        let latest_seq = latest_canvas_seq_query(&mut *tx, channel_id).await?;
        let row = sqlx::query!(
            r#"SELECT COUNT(*) AS "count!: i64",
                      MIN(x) AS "min_x: f64", MIN(y) AS "min_y: f64",
                      MAX(x + w) AS "max_x: f64", MAX(y + h) AS "max_y: f64"
               FROM canvas_objects
               WHERE channel_id = ? AND deleted_at IS NULL"#,
            channel_id
        )
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;
        let bounds = match (row.min_x, row.min_y, row.max_x, row.max_y) {
            (Some(min_x), Some(min_y), Some(max_x), Some(max_y)) => Some(Rect {
                min_x,
                min_y,
                max_x,
                max_y,
            }),
            _ => None,
        };
        Ok(CanvasSummary {
            count: row.count,
            bounds,
            latest_seq,
        })
    }
}
