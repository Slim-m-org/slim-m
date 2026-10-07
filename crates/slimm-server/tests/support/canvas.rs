// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas reads and removals for tests, built on the same paths the product uses.

use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasObject, CanvasOpRequest, Rect, Store, ViewportQuery};

/// Reads the product answers only as one `viewport_snapshot`, kept under their old names.
pub trait CanvasReads {
    async fn latest_canvas_seq(&self, channel_id: ChannelId) -> anyhow::Result<i64>;

    async fn viewport_objects(
        &self,
        channel_id: ChannelId,
        query: &ViewportQuery,
    ) -> anyhow::Result<Vec<CanvasObject>>;
}

impl CanvasReads for Store {
    async fn latest_canvas_seq(&self, channel_id: ChannelId) -> anyhow::Result<i64> {
        let nothing = ViewportQuery {
            view: Rect {
                min_x: 0.0,
                min_y: 0.0,
                max_x: 0.0,
                max_y: 0.0,
            },
            previous: None,
            after_seq: 0,
            limit: 1,
        };
        Ok(self.viewport_snapshot(channel_id, &nothing).await?.0)
    }

    async fn viewport_objects(
        &self,
        channel_id: ChannelId,
        query: &ViewportQuery,
    ) -> anyhow::Result<Vec<CanvasObject>> {
        Ok(self.viewport_snapshot(channel_id, query).await?.1)
    }
}

/// Removes one object through a `remove` op, the only way the product removes anything.
pub async fn remove_via_op(
    store: &Store,
    channel_id: ChannelId,
    actor_id: UserId,
    object_id: CanvasObjectId,
) {
    store
        .submit_canvas_op(
            channel_id,
            actor_id,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Remove(vec![object_id]),
        )
        .await
        .unwrap_or_else(|_| panic!("remove op for {object_id:?} refused"));
}
