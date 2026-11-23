// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Payloads of the `canvas.*` server frames; each is flattened into the frame by `ServerFrame`.

use std::sync::Arc;

use serde::Serialize;

use crate::http::canvas::CanvasObjectDto;

fn is_zero(n: &i64) -> bool {
    *n == 0
}

#[derive(Serialize)]
pub(super) struct ObjectPlaced {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) object: CanvasObjectDto,
}

#[derive(Serialize)]
pub(super) struct ObjectsRemoved {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) object_ids: Vec<String>,
}

#[derive(Serialize)]
pub(super) struct Cleared {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) before_seq: i64,
}

#[derive(Serialize)]
pub(super) struct ClearedScoped {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) before_seq: i64,
    pub(super) kinds: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) author_id: Option<String>,
    /// Locked objects the clear left standing; fewer ids than `spared_count` means refetch.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub(super) spared_ids: Vec<String>,
    #[serde(skip_serializing_if = "is_zero")]
    pub(super) spared_count: i64,
}

#[derive(Serialize)]
pub(super) struct ObjectsRestored {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) object_ids: Vec<String>,
}

#[derive(Serialize)]
pub(super) struct CursorMoved {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub(super) left: bool,
}

#[derive(Serialize)]
pub(super) struct StrokePreview {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) object_id: String,
    pub(super) points: Vec<f64>,
    pub(super) ended: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(super) cancelled: bool,
    pub(super) color: Option<String>,
    pub(super) width: Option<f64>,
}

#[derive(Serialize)]
pub(super) struct ObjectPreview {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) object_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) w: f64,
    pub(super) h: f64,
    pub(super) ended: bool,
}

#[derive(Serialize)]
pub(super) struct MediaSlotPreview {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) kind: String,
    pub(super) slot_user_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) w: f64,
    pub(super) h: f64,
    pub(super) ended: bool,
}

#[derive(Serialize)]
pub(super) struct ScreenAnnotation {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) target_user_id: String,
    pub(super) kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) annotation_id: Option<String>,
    pub(super) points: Vec<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) text: Option<String>,
    pub(super) ended: bool,
    pub(super) allowed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) aspect: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) size: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) emoji: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) attachment: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub(super) animated: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub(super) stamps: bool,
}

#[derive(Serialize)]
pub(super) struct View {
    pub(super) channel_id: String,
    pub(super) user_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) w: f64,
    pub(super) h: f64,
    pub(super) summon: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) tile: Option<String>,
}

#[derive(Serialize)]
pub(super) struct ObjectMoved {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) object_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) w: f64,
    pub(super) h: f64,
}

#[derive(Serialize)]
pub(super) struct ObjectReordered {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) object_id: String,
    pub(super) z_index: i64,
}

#[derive(Serialize)]
pub(super) struct ObjectEdited {
    pub(super) channel_id: String,
    pub(super) seq: i64,
    pub(super) op_id: String,
    pub(super) object_id: String,
    pub(super) props: serde_json::Value,
}

#[derive(Serialize)]
pub(super) struct MediaSlotChanged {
    pub(super) channel_id: String,
    pub(super) kind: String,
    pub(super) user_id: String,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) w: f64,
    pub(super) h: f64,
    pub(super) locked: bool,
    pub(super) sent_to_back: bool,
    pub(super) version: i64,
}

#[derive(Serialize)]
pub(super) struct ObjectLockChanged {
    pub(super) channel_id: String,
    pub(super) object_id: String,
    pub(super) locked: bool,
    pub(super) version: i64,
}

#[derive(Serialize)]
pub(super) struct TileSceneChanged {
    pub(super) channel_id: String,
    pub(super) object_id: String,
    pub(super) output: Arc<str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) ran_by: Option<String>,
    pub(super) ran_at: i64,
}
