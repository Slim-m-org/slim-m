// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A forward shows the files it passes on as the message it names showed
//! them: under that message's name for the bytes, and still hidden if it hid them.

use serde_json::{Value, json};
use tower::ServiceExt;
use uuid::Uuid;

use crate::attachments::fixtures::*;
use crate::attachments::text_search::{World, world};

async fn send(world: &World, token: &str, body: Value) -> String {
    let id = Uuid::now_v7().to_string();
    let mut body = body;
    body["id"] = json!(id);
    body["content"] = json!("");
    let response = world
        .app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", world.channel),
            token,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    id
}

async fn shown(world: &World, message_id: &str) -> Value {
    let response = world
        .app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/channels/{}/messages", world.channel),
            &world.token,
        ))
        .await
        .unwrap();
    let list = json_body(response).await;
    let messages = list
        .as_array()
        .cloned()
        .unwrap_or_else(|| list["messages"].as_array().unwrap().clone());
    let message = messages.iter().find(|m| m["id"] == message_id).unwrap();
    message["attachments"][0].clone()
}

#[tokio::test]
async fn a_forward_shows_the_name_the_original_showed() {
    let world = world().await;
    let (bob, _) = register(&world.store, "bob").await;
    let (carol, _) = register(&world.store, "carol").await;
    upload(&world.app, &bob, "bob-salary-2026.png", png(4)).await;
    let (alices, id) = world.send("", "template.png", png(4)).await;
    let forward = json!({ "attachment_ids": [id], "forwarded_from_id": alices });

    let carols = send(&world, &carol, forward.clone()).await;
    assert_eq!(
        shown(&world, &carols).await["filename"],
        "template.png",
        "not the first upload's name"
    );
    let bobs = send(&world, &bob, forward).await;
    assert_eq!(
        shown(&world, &bobs).await["filename"],
        "template.png",
        "not the forwarder's own name for the bytes"
    );
    let relayed = json!({ "attachment_ids": [id], "forwarded_from_id": carols });
    let again = send(&world, &bob, relayed).await;
    assert_eq!(shown(&world, &again).await["filename"], "template.png");

    let found: Vec<Value> = world.search("salary").await;
    assert!(found.is_empty(), "{found:?}");
}

#[tokio::test]
async fn a_forward_of_a_hidden_file_stays_hidden() {
    let world = world().await;
    let (carol, _) = register(&world.store, "carol").await;
    let id = upload(&world.app, &world.token, "ending.png", png(4)).await["id"].clone();
    let hidden = json!({ "attachment_ids": [id], "spoiler_attachment_ids": [id] });
    let hidden = send(&world, &world.token, hidden).await;

    let carols = send(
        &world,
        &carol,
        json!({ "attachment_ids": [id], "forwarded_from_id": hidden }),
    )
    .await;
    assert_eq!(shown(&world, &carols).await["spoiler"], true);
    let again = send(
        &world,
        &world.token,
        json!({ "attachment_ids": [id], "forwarded_from_id": carols }),
    )
    .await;
    assert_eq!(
        shown(&world, &again).await["spoiler"],
        true,
        "a forward of a forward"
    );

    let plain = send(&world, &world.token, json!({ "attachment_ids": [id] })).await;
    let added = json!({
        "attachment_ids": [id],
        "spoiler_attachment_ids": [id],
        "forwarded_from_id": plain,
    });
    let carols = send(&world, &carol, added).await;
    assert_eq!(
        shown(&world, &carols).await["spoiler"],
        true,
        "a forwarder may still hide what they pass on"
    );
    let unhidden = send(
        &world,
        &carol,
        json!({ "attachment_ids": [id], "forwarded_from_id": plain }),
    )
    .await;
    assert_eq!(shown(&world, &unhidden).await.get("spoiler"), None);
}
