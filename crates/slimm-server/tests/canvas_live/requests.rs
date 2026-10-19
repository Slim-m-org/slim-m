// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One request builder per canvas op, all aimed at the same channel route.

use axum::body::Body;
use axum::http::Request;
use serde_json::json;
use slimm_server::ids::ChannelId;
use uuid::Uuid;

pub(crate) fn place_request(channel: ChannelId, token: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/objects"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "stroke",
                "x": 4.0, "y": 5.0, "w": 6.0, "h": 7.0,
                "props": { "points": [0.0, 0.0, 6.0, 7.0], "width": 3.0, "color": "annotation" },
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn remove_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "remove",
                "object_ids": [object_id],
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn clear_request(channel: ChannelId, token: &str, before_seq: i64) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "clear",
                "before_seq": before_seq,
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn move_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "move",
                "object_id": object_id,
                "x": 9.0, "y": 9.0, "w": 9.0, "h": 9.0,
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn reorder_request(channel: ChannelId, token: &str, object_id: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "reorder",
                "object_id": object_id,
                "z_index": 500,
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn restore_request(channel: ChannelId, token: &str, target_op: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "restore",
                "target_op": target_op,
            })
            .to_string(),
        ))
        .unwrap()
}

pub(crate) fn scoped_clear_request(channel: ChannelId, token: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/channels/{channel}/canvas/ops"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "clear",
                "before_seq": 100,
                "kinds": ["stroke"],
            })
            .to_string(),
        ))
        .unwrap()
}
