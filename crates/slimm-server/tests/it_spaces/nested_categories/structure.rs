// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Two levels at most on every write path, refused before any id is read for a
//! non-manager, and a move un-syncing without changing who sees what.

use axum::http::StatusCode;
use serde_json::{Value, json};

use super::world::{World, category_events, groups_of, has, order_body, world};

async fn patch_parent(w: &World, id: &str, parent: &str) -> StatusCode {
    let body = json!({"parent_id": parent});
    let uri = format!("/categories/{id}");
    w.call("PATCH", &uri, &w.admin, Some(body)).await.0
}

#[tokio::test]
async fn a_third_level_is_refused_on_create_patch_and_order() {
    let w = world("slimm-nested-depth").await;
    let solo = w.create_category("solo", None).await;
    let create = |parent: &str| json!({"name": "deep", "parent_id": parent});
    let (status, body) = w
        .call("POST", "/categories", &w.admin, Some(create(&w.cs2)))
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "under a sub-category: {body}");
    let unknown = uuid::Uuid::now_v7().to_string();
    let (status, _) = w
        .call("POST", "/categories", &w.admin, Some(create(&unknown)))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    assert_eq!(patch_parent(&w, &solo, &w.cs2).await, StatusCode::CONFLICT);
    assert_eq!(
        patch_parent(&w, &w.gamers, &solo).await,
        StatusCode::CONFLICT
    );
    assert_eq!(
        patch_parent(&w, &solo, &solo).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        patch_parent(&w, &solo, &unknown).await,
        StatusCode::BAD_REQUEST
    );

    let listed = w.categories(&w.admin).await;
    let mut groups = groups_of(&listed);
    groups[0].1.retain(|id| *id != solo);
    groups.push((json!(w.cs2), vec![solo.clone()]));
    let (status, body) = w
        .call(
            "PUT",
            "/categories/order",
            &w.admin,
            Some(order_body(&groups)),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");

    let mut short = groups_of(&listed);
    short[0].1.retain(|id| *id != solo);
    let (status, body) = w
        .call(
            "PUT",
            "/categories/order",
            &w.admin,
            Some(order_body(&short)),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body.to_string().contains(&solo),
        "names the missing id: {body}"
    );

    let mut twice = groups_of(&listed);
    twice.push((Value::Null, Vec::new()));
    let (status, _) = w
        .call(
            "PUT",
            "/categories/order",
            &w.admin,
            Some(order_body(&twice)),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a repeated parent");

    let after = w.categories(&w.admin).await;
    assert_eq!(listed, after, "no refusal wrote anything");
}

#[tokio::test]
async fn a_non_manager_is_refused_before_any_id_is_read() {
    let w = world("slimm-nested-gate").await;
    let unknown = uuid::Uuid::now_v7().to_string();
    let body = json!({"groups": [{"parent_id": unknown, "category_ids": ["not-a-uuid"]}]});
    let (status, _) = w
        .call("PUT", "/categories/order", &w.gamer.token, Some(body))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let body = json!({"name": "x", "parent_id": unknown});
    let (status, _) = w
        .call("POST", "/categories", &w.gamer.token, Some(body))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let uri = format!("/categories/{}", w.cs2);
    let body = json!({"parent_id": unknown});
    let (status, _) = w.call("PATCH", &uri, &w.gamer.token, Some(body)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn moving_a_category_unsyncs_it_and_keeps_who_can_see_its_channels() {
    let mut w = world("slimm-nested-move").await;
    let other = w.create_category("other", None).await;
    let tail = w.create_category("tail", Some(&other)).await;
    w.drain();
    let uri = format!("/categories/{}", w.minecraft);
    let moved = w
        .ok("PATCH", &uri, &w.admin, Some(json!({"parent_id": other})))
        .await;
    assert_eq!(moved["parent_id"], json!(other));
    assert_eq!(category_events(&w.drain()), (1, 0));
    let siblings: Vec<String> = w
        .categories(&w.admin)
        .await
        .into_iter()
        .filter(|c| c["parent_id"] == json!(other))
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(siblings, vec![tail, w.minecraft.clone()], "appended");
    assert_eq!(w.overwrites(&w.minecraft).await["synced"], json!(false));
    assert!(has(&w.channel_names(&w.gamer.token).await, "mc-chat"));
    assert!(!has(&w.channel_names(&w.neither.token).await, "mc-chat"));

    let top = w
        .ok("PATCH", &uri, &w.admin, Some(json!({"parent_id": null})))
        .await;
    assert!(top["parent_id"].is_null());
    assert!(w.overwrites(&w.minecraft).await.get("synced").is_none());
}
