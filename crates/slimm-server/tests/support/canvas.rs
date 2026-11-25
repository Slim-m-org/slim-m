// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Canvas reads and removals for tests, built on the same paths the product uses.

use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{
    CanvasObject, CanvasOpRequest, Channel, ChannelDefaults, Rect, Store, ViewportQuery,
};
use sqlx::SqlitePool;

/// Channels whose board is open, for the tests whose subject is the board and not the channel's kind.
pub trait BoardChannels {
    /// A voice channel with its canvas on, as one made before the toggle was.
    async fn create_voice_with_canvas(&self, name: &str) -> anyhow::Result<Channel>;

    /// A canvas channel, with a call when `call` is true.
    async fn create_canvas_channel(&self, name: &str, call: bool) -> anyhow::Result<Channel>;
}

impl BoardChannels for Store {
    async fn create_voice_with_canvas(&self, name: &str) -> anyhow::Result<Channel> {
        create_with(self, name, "voice", true, false).await
    }

    async fn create_canvas_channel(&self, name: &str, call: bool) -> anyhow::Result<Channel> {
        create_with(self, name, "canvas", false, call).await
    }
}

async fn create_with(
    store: &Store,
    name: &str,
    kind: &str,
    canvas_enabled: bool,
    voice_enabled: bool,
) -> anyhow::Result<Channel> {
    let defaults = ChannelDefaults {
        canvas_enabled,
        voice_enabled,
        ..ChannelDefaults::default()
    };
    let created = store
        .create_channel_with_id(ChannelId::generate(), name, kind, None, None, defaults)
        .await
        .map_err(|err| anyhow::anyhow!("create {kind} channel: {err:?}"))?;
    Ok(created.channel)
}

pub const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Moves every canvas op and erased object `days` into the past, so the retention sweeps see them as old.
pub async fn age_canvas_history(pool: &SqlitePool, days: i64) {
    sqlx::query("UPDATE canvas_ops SET created_at = created_at - ?")
        .bind(days * DAY_MS)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IS NOT NULL",
    )
    .bind(days * DAY_MS)
    .execute(pool)
    .await
    .unwrap();
}

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

/// Gives every object inserted by raw SQL its props row, which the store's reads join on.
#[allow(dead_code)]
pub async fn backfill_props(pool: &SqlitePool) {
    sqlx::query(
        "INSERT INTO canvas_object_props (object_id, props)
         SELECT id, '{}' FROM canvas_objects
         WHERE id NOT IN (SELECT object_id FROM canvas_object_props)",
    )
    .execute(pool)
    .await
    .unwrap();
}
