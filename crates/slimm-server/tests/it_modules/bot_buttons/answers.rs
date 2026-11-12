// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! See docs/decisions/0039-bot-message-buttons.md.

use super::*;

#[tokio::test]
async fn a_private_reply_to_a_press_reaches_only_the_clicker_and_is_budgeted() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;
    let (_, _, id) = press(&w, &w.alice.1, &sent, "hit").await;

    assert_eq!(
        whisper(&w, &w.bot.1, &id, "you drew a king").await,
        StatusCode::OK
    );
    let heard = frame_of_kind(&mut alice, "message.ephemeral")
        .await
        .expect("the clicker hears it");
    assert_eq!(heard["message"]["content"], "you drew a king");
    assert!(
        frame_of_kind(&mut alice, "interaction.answered")
            .await
            .is_some()
    );
    assert!(frame_of_kind(&mut bob, "message.ephemeral").await.is_none());
    assert!(
        frame_of_kind(&mut bob, "interaction.answered")
            .await
            .is_none()
    );

    assert_eq!(whisper(&w, &w.bot.1, &id, "two").await, StatusCode::OK);
    assert_eq!(whisper(&w, &w.bot.1, &id, "three").await, StatusCode::OK);
    assert_eq!(
        whisper(&w, &w.bot.1, &id, "four").await,
        StatusCode::TOO_MANY_REQUESTS,
        "three replies per press"
    );
}

#[tokio::test]
async fn another_bot_cannot_answer_a_press_it_was_not_sent() {
    let w = world().await;
    let sent = posted(&w).await;
    let (_, _, id) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(
        whisper(&w, &w.other_bot.1, &id, "gotcha").await,
        StatusCode::NOT_FOUND
    );
    let (status, _) = call(
        &w,
        "POST",
        &format!("/channels/{}/interactions/{id}/ack", w.channel),
        &w.other_bot.1,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_ack_tells_the_clicker_once_and_nobody_else() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;
    let (_, _, id) = press(&w, &w.alice.1, &sent, "hit").await;
    let uri = format!("/channels/{}/interactions/{id}/ack", w.channel);
    for _ in 0..2 {
        let (status, _) = call(&w, "POST", &uri, &w.bot.1, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    let frame = frame_of_kind(&mut alice, "interaction.answered")
        .await
        .unwrap();
    assert_eq!(frame["interaction_id"], id);
    assert!(
        frame_of_kind(&mut alice, "interaction.answered")
            .await
            .is_none(),
        "told once"
    );
    assert!(
        frame_of_kind(&mut bob, "interaction.answered")
            .await
            .is_none()
    );
}

#[tokio::test]
async fn a_bot_replaces_its_buttons_and_every_viewer_is_told() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let (_, _, id) = press(&w, &w.alice.1, &sent, "stand").await;

    let uri = format!(
        "/channels/{}/messages/{}/components",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    let disabled = json!([{ "buttons": [{ "label": "Hit", "style": "primary", "custom_id": "hit", "disabled": true }] }]);
    let (status, _) = call(
        &w,
        "PUT",
        &uri,
        &w.bot.1,
        Some(json!({ "components": disabled, "interaction_id": id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let frame = frame_of_kind(&mut bob, "message.components").await.unwrap();
    assert_eq!(frame["components"][0]["buttons"][0]["disabled"], true);
    assert!(
        frame_of_kind(&mut alice, "interaction.answered")
            .await
            .is_some(),
        "an edit that names the press answers it"
    );

    let (status, _, _) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a disabled button cannot be pressed"
    );
    let (status, _) = call(
        &w,
        "PUT",
        &uri,
        &w.other_bot.1,
        Some(json!({ "components": [] })),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "only the author bot may change them"
    );
    let (status, _) = call(
        &w,
        "PUT",
        &uri,
        &w.alice.1,
        Some(json!({ "components": [] })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, cleared) =
        call(&w, "PUT", &uri, &w.bot.1, Some(json!({ "components": [] }))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(cleared["components"], json!([]));
    let (_, page) = call(
        &w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    assert_eq!(page[0]["components"], json!([]));
}
