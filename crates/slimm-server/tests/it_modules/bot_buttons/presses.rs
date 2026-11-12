// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! See docs/decisions/0039-bot-message-buttons.md.

use super::*;

#[tokio::test]
async fn a_press_reaches_only_the_owning_bot_and_a_retry_is_the_same_press() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let mut rival = connect(&w, addr, &w.other_bot.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let (status, _, id) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(status, StatusCode::OK);
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the owning bot hears it");
    assert_eq!(frame["interaction_id"], id);
    assert_eq!(frame["custom_id"], "hit");
    assert_eq!(frame["user_id"], w.alice.0.to_string());
    assert_eq!(frame["message_id"], sent["id"]);
    for (who, ws) in [("another bot", &mut rival), ("another member", &mut bob)] {
        assert!(
            frame_of_kind(ws, "interaction.created").await.is_none(),
            "{who} must not hear a press"
        );
    }

    let uri = format!(
        "/channels/{}/messages/{}/interactions",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    let (status, _) = call(
        &w,
        "POST",
        &uri,
        &w.alice.1,
        Some(json!({ "id": id, "custom_id": "hit" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        frame_of_kind(&mut bot, "interaction.created")
            .await
            .is_none(),
        "a retry is not a second press"
    );
    let (status, _) = call(
        &w,
        "POST",
        &uri,
        &w.bob.1,
        Some(json!({ "id": id, "custom_id": "hit" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "an id belongs to one clicker");
}

#[tokio::test]
async fn only_a_live_enabled_button_on_a_bots_message_can_be_pressed() {
    let w = world().await;
    let sent = posted(&w).await;
    let (status, _, _) = press(&w, &w.alice.1, &sent, "nope").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _, _) = press(&w, &w.alice.1, &sent, "rules").await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a link button never reaches a bot"
    );
    let (status, _, _) = press(&w, &w.bot.1, &sent, "hit").await;
    assert_eq!(status, StatusCode::FORBIDDEN, "a bot cannot press");

    let plain = call(
        &w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        &w.bob.1,
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "hi" })),
    )
    .await
    .1;
    let (status, _, _) = press(&w, &w.alice.1, &plain, "hit").await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let uri = format!(
        "/channels/{}/messages/{}",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    call(&w, "DELETE", &uri, &w.bot.1, None).await;
    let (status, _, _) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a deleted message has no buttons"
    );
}

#[tokio::test]
async fn a_held_down_button_is_rate_limited_per_clicker() {
    let w = world().await;
    let sent = posted(&w).await;
    let mut last = StatusCode::OK;
    for _ in 0..12 {
        last = press(&w, &w.alice.1, &sent, "hit").await.0;
    }
    assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
    let (status, _, _) = press(&w, &w.bob.1, &sent, "hit").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "another clicker has their own budget"
    );
}

#[tokio::test]
async fn a_press_on_a_revoked_bots_button_is_refused_with_a_reason() {
    let w = world().await;
    let sent = posted(&w).await;
    let (status, _, _) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(status, StatusCode::OK, "a live bot hears the press");

    w.state
        .store
        .revoke_bot(w.bot.0, w.alice.0)
        .await
        .unwrap()
        .expect("the bot exists");
    let (status, body, id) = press(&w, &w.bob.1, &sent, "hit").await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(
        body["error"],
        "that bot has been removed, so its buttons no longer work"
    );
    let stored = w
        .state
        .store
        .interaction(slimm_server::ids::InteractionId(id.parse().unwrap()))
        .await
        .unwrap();
    assert!(stored.is_none(), "a press nobody can answer stores nothing");
}
