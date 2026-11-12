// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! See docs/decisions/0039-bot-message-buttons.md.

use super::*;

#[tokio::test]
async fn buttons_ride_send_list_and_sync_and_only_a_bot_may_post_them() {
    let w = world().await;
    let sent = posted(&w).await;
    assert_eq!(sent["components"][0]["buttons"][1]["custom_id"], "stand");

    let uri = format!("/channels/{}/messages", w.channel);
    let (_, page) = call(&w, "GET", &uri, &w.alice.1, None).await;
    assert_eq!(page[0]["components"], sent["components"]);
    let scopes = json!({ "scopes": [{ "channel_id": w.channel.to_string(), "after_seq": 0 }] });
    let (_, synced) = call(&w, "POST", "/sync", &w.alice.1, Some(scopes)).await;
    assert_eq!(
        synced["scopes"][0]["messages"][0]["components"],
        sent["components"]
    );

    let (status, _) = post_with(&w, &w.alice.1, buttons()).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a member cannot post buttons"
    );
}

#[tokio::test]
async fn the_live_frame_and_an_edit_keep_the_buttons() {
    let w = world().await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let sent = posted(&w).await;
    let created = frame_of_kind(&mut alice, "message.created").await.unwrap();
    assert_eq!(created["message"]["components"], sent["components"]);

    let uri = format!(
        "/channels/{}/messages/{}",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    let (status, _) = call(
        &w,
        "PATCH",
        &uri,
        &w.bot.1,
        Some(json!({ "content": "new text" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, page) = call(
        &w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    assert_eq!(page[0]["content"], "new text");
    assert_eq!(
        page[0]["components"], sent["components"],
        "an edit must not drop the buttons"
    );
}

#[tokio::test]
async fn the_caps_are_enforced() {
    let w = world().await;
    let six_rows: Vec<Value> = (0..6)
        .map(|r| json!({ "buttons": [{ "label": "x", "style": "primary", "custom_id": format!("r{r}") }] }))
        .collect();
    let six_wide = json!([{ "buttons": (0..6)
        .map(|c| json!({ "label": "x", "style": "primary", "custom_id": format!("c{c}") }))
        .collect::<Vec<_>>() }]);
    let long_label =
        json!([{ "buttons": [{ "label": "x".repeat(81), "style": "primary", "custom_id": "a" }] }]);
    let long_id = json!([{ "buttons": [{ "label": "x", "style": "primary", "custom_id": "i".repeat(101) }] }]);
    let bad_link =
        json!([{ "buttons": [{ "label": "x", "style": "link", "url": "javascript:alert(1)" }] }]);
    for bad in [json!(six_rows), six_wide, long_label, long_id, bad_link] {
        let (status, _) = post_with(&w, &w.bot.1, bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}
