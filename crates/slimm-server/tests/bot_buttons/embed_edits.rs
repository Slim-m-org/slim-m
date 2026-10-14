// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot editing its message's embeds in place, the way a status board does.

use super::*;

async fn post_embed(w: &World, token: &str, title: &str) -> Value {
    let (status, body) = call(
        w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        token,
        Some(json!({
            "id": Uuid::now_v7().to_string(),
            "content": "status",
            "embeds": [{ "title": title }],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn edit(w: &World, token: &str, message: &Value, body: Value) -> (StatusCode, Value) {
    let uri = format!(
        "/channels/{}/messages/{}",
        w.channel,
        message["id"].as_str().unwrap()
    );
    call(w, "PATCH", &uri, token, Some(body)).await
}

async fn stored_titles(w: &World, message: &Value) -> Vec<String> {
    let (_, list) = call(
        w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    let found = list
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == message["id"])
        .unwrap()
        .clone();
    found["embeds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["title"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn a_bot_edit_replaces_its_embeds_and_every_viewer_is_told() {
    let w = world().await;
    let sent = post_embed(&w, &w.bot.1, "Up").await;
    let addr = serve(w.state.clone()).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let body =
        json!({ "content": "status", "embeds": [{ "title": "Down", "description": "2 of 3" }] });
    let (status, edited) = edit(&w, &w.bot.1, &sent, body).await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["embeds"][0]["title"], "Down");

    let frame = frame_of_kind(&mut bob, "message.embeds")
        .await
        .expect("an unchanged text still announces the new embeds");
    assert_eq!(frame["message_id"], sent["id"]);
    assert_eq!(frame["embeds"][0]["description"], "2 of 3");
    assert_eq!(stored_titles(&w, &sent).await, ["Down"]);
}

#[tokio::test]
async fn an_empty_list_clears_and_a_text_only_edit_keeps_them() {
    let w = world().await;
    let sent = post_embed(&w, &w.bot.1, "Up").await;
    let addr = serve(w.state.clone()).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let (status, edited) = edit(&w, &w.bot.1, &sent, json!({ "content": "new text" })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        edited["embeds"][0]["title"], "Up",
        "no embeds field, no change"
    );
    assert!(frame_of_kind(&mut bob, "message.embeds").await.is_none());

    let body = json!({ "content": "new text", "embeds": [] });
    let (status, edited) = edit(&w, &w.bot.1, &sent, body).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(edited["embeds"], json!([]));
    let frame = frame_of_kind(&mut bob, "message.embeds").await.unwrap();
    assert_eq!(frame["embeds"], json!([]));
    assert!(stored_titles(&w, &sent).await.is_empty());
}

#[tokio::test]
async fn only_the_bot_that_wrote_it_changes_its_embeds() {
    let w = world().await;
    let own = post_embed(&w, &w.alice.1, "ignored").await;
    assert_eq!(
        own["embeds"],
        json!([]),
        "a person's embeds were never kept"
    );
    let body = json!({ "content": "edited", "embeds": [{ "title": "Sneaky" }] });
    let (status, edited) = edit(&w, &w.alice.1, &own, body).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        edited["embeds"],
        json!([]),
        "dropped from a person, as on send"
    );

    let sent = post_embed(&w, &w.bot.1, "Up").await;
    let body = json!({ "content": "status", "embeds": [{ "title": "Hijacked" }] });
    let (status, _) = edit(&w, &w.other_bot.1, &sent, body).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "another bot cannot edit it at all"
    );
    assert_eq!(stored_titles(&w, &sent).await, ["Up"]);
}

#[tokio::test]
async fn a_refused_embed_leaves_the_text_unedited() {
    let w = world().await;
    let sent = post_embed(&w, &w.bot.1, "Up").await;
    let long = "x".repeat(300);
    let body = json!({ "content": "half done", "embeds": [{ "title": long }] });
    let (status, _) = edit(&w, &w.bot.1, &sent, body).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (_, list) = call(
        &w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    let found = list
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == sent["id"])
        .unwrap()
        .clone();
    assert_eq!(found["content"], "status");
    assert_eq!(stored_titles(&w, &sent).await, ["Up"]);
}
