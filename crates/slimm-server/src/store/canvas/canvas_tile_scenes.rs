// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module tile's shared frame and its host redraws; see migration `0205_canvas_tile_scenes.sql`.

use sqlx::{AssertSqlSafe, Row};

use super::super::{Store, now_ms};
use crate::ids::{CanvasObjectId, ChannelId, UserId};

/// The canvas object kind a module tile is stored as.
pub const MODULE_TILE_KIND: &str = "module";

/// The manifest extension point kind a module declares a tile with.
pub const CANVAS_TILE_POINT: &str = "canvas-tile";

/// Which module and which of its `canvas-tile` points a live tile object names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleTileRef {
    pub module_id: String,
    pub tile: String,
}

impl ModuleTileRef {
    /// Reads `props.module_id` and `props.tile`, or `None` when either is missing or not a string.
    pub fn from_props(props: &serde_json::Value) -> Option<Self> {
        let field = |name: &str| props.get(name)?.as_str().map(str::to_owned);
        Some(Self {
            module_id: field("module_id")?,
            tile: field("tile")?,
        })
    }
}

/// A tile's last stored frame.
#[derive(Debug, Clone)]
pub struct TileScene {
    pub output: String,
    pub ran_by: Option<UserId>,
    pub ran_at: i64,
}

impl Store {
    /// The module a live module tile in `channel_id` names, or `None` for any other object.
    pub async fn live_module_tile(
        &self,
        channel_id: ChannelId,
        object_id: CanvasObjectId,
    ) -> anyhow::Result<Option<ModuleTileRef>> {
        let row = sqlx::query(
            "SELECT p.props AS props FROM canvas_objects o \
             JOIN canvas_object_props p ON p.object_id = o.id \
             WHERE o.id = ? AND o.channel_id = ? AND o.kind = ? AND o.deleted_at IS NULL",
        )
        .bind(object_id)
        .bind(channel_id)
        .bind(MODULE_TILE_KIND)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else { return Ok(None) };
        let props: String = row.try_get("props")?;
        let props = serde_json::from_str(&props).unwrap_or(serde_json::Value::Null);
        Ok(ModuleTileRef::from_props(&props))
    }

    pub async fn canvas_tile_scene(
        &self,
        object_id: CanvasObjectId,
    ) -> anyhow::Result<Option<TileScene>> {
        let row = sqlx::query(
            "SELECT output, ran_by, ran_at FROM canvas_tile_scenes WHERE object_id = ?",
        )
        .bind(object_id)
        .fetch_optional(&self.pool)
        .await?;
        row.map(|row| {
            Ok(TileScene {
                output: row.try_get("output")?,
                ran_by: row.try_get("ran_by")?,
                ran_at: row.try_get("ran_at")?,
            })
        })
        .transpose()
    }

    /// Replaces a tile's frame and answers when it was stored. A pending redraw is kept.
    pub async fn record_canvas_tile_scene(
        &self,
        (channel_id, object_id): (ChannelId, CanvasObjectId),
        output: &str,
        ran_by: UserId,
    ) -> anyhow::Result<i64> {
        let now = now_ms();
        sqlx::query(
            "INSERT INTO canvas_tile_scenes (object_id, channel_id, output, ran_by, ran_at) \
             VALUES (?, ?, ?, ?, ?) \
             ON CONFLICT (object_id) DO UPDATE SET \
                 output = excluded.output, ran_by = excluded.ran_by, ran_at = excluded.ran_at",
        )
        .bind(object_id)
        .bind(channel_id)
        .bind(output)
        .bind(ran_by)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(now)
    }

    /// Queues the next redraw of a stored tile frame; `extend` renews the window, as a person's press does.
    /// Without `extend` it continues a running chain only, so a press that just ended it stays ended.
    pub async fn schedule_canvas_tile_refresh(
        &self,
        object_id: CanvasObjectId,
        (due_at, until_at): (i64, i64),
        extend: bool,
    ) -> anyhow::Result<()> {
        let (until, chain) = if extend {
            ("?", "")
        } else {
            ("refresh_until_at", " AND refresh_until_at IS NOT NULL")
        };
        let sql = format!(
            "UPDATE canvas_tile_scenes SET refresh_due_at = ?, refresh_until_at = {until} \
             WHERE object_id = ?{chain}"
        );
        let query = sqlx::query(AssertSqlSafe(sql)).bind(due_at);
        let query = if extend { query.bind(until_at) } else { query };
        query.bind(object_id).execute(&self.pool).await?;
        Ok(())
    }

    pub async fn clear_canvas_tile_refresh(&self, object_id: CanvasObjectId) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE canvas_tile_scenes SET refresh_due_at = NULL, refresh_until_at = NULL \
             WHERE object_id = ?",
        )
        .bind(object_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Tiles whose redraw is due at `now`, oldest first, with their channel and when each chain ends.
    pub async fn due_canvas_tile_refreshes(
        &self,
        now: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<(CanvasObjectId, ChannelId, i64)>> {
        let rows = sqlx::query(
            "SELECT object_id, channel_id, refresh_until_at FROM canvas_tile_scenes \
             WHERE refresh_due_at IS NOT NULL AND refresh_due_at <= ? \
             ORDER BY refresh_due_at LIMIT ?",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(|row| {
                Ok((
                    row.try_get("object_id")?,
                    row.try_get("channel_id")?,
                    row.try_get::<Option<i64>, _>("refresh_until_at")?
                        .unwrap_or(0),
                ))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::ModuleTileRef;
    use serde_json::json;

    #[test]
    fn a_tile_names_its_module_and_tile_as_strings() {
        let tile = ModuleTileRef::from_props(&json!({"module_id": "dice", "tile": "Board"}));
        assert_eq!(
            tile,
            Some(ModuleTileRef {
                module_id: "dice".into(),
                tile: "Board".into()
            })
        );
        assert_eq!(
            ModuleTileRef::from_props(&json!({"module_id": "dice"})),
            None
        );
        assert_eq!(
            ModuleTileRef::from_props(&json!({"module_id": 1, "tile": "Board"})),
            None
        );
    }
}
