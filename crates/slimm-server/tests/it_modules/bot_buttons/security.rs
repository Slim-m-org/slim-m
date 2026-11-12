// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A press id and a message id are separate things: neither can be aimed at the
//! other, and a button's text cannot pose as something else.
//! See docs/decisions/0039-bot-message-buttons.md.

use super::*;

/// A member's message that mentions the helper bot, so the bot may answer its author.
async fn addressed_message(w: &World, token: &str) -> Value {
    let (status, message) = call(
        w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        token,
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "@helper hello" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    message
}

#[tokio::test]
async fn a_press_cannot_take_a_message_id_to_hijack_a_whisper() {
    let w = world().await;
    let sent = posted(&w).await;
    let alices = addressed_message(&w, &w.alice.1).await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let hijack = press_as(&w, &w.bob.1, &sent, "hit", alices["id"].as_str().unwrap()).await;
    assert_eq!(
        hijack,
        StatusCode::CONFLICT,
        "a message id is not a press id"
    );

    let id = alices["id"].as_str().unwrap();
    assert_eq!(
        whisper_to_message(&w, &w.bot.1, id, "for alice only").await,
        StatusCode::OK
    );
    assert!(
        frame_of_kind(&mut alice, "message.ephemeral")
            .await
            .is_some()
    );
    assert!(
        frame_of_kind(&mut bob, "message.ephemeral").await.is_none(),
        "the whisper must not be redirected to the presser"
    );
}

#[tokio::test]
async fn a_press_never_shadows_a_message_anchor_for_anyone() {
    let w = world().await;
    let sent = posted(&w).await;
    let (_, _, press_id) = press(&w, &w.bob.1, &sent, "hit").await;

    // The rival bot cannot use bob's press, as a press or as a message.
    assert_eq!(
        whisper(&w, &w.other_bot.1, &press_id, "x").await,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        whisper_to_message(&w, &w.other_bot.1, &press_id, "x").await,
        StatusCode::NOT_FOUND,
        "a press id is not readable as a message anchor"
    );
    // And the owning bot cannot read a message id as a press.
    let alices = addressed_message(&w, &w.alice.1).await;
    assert_eq!(
        whisper(&w, &w.bot.1, alices["id"].as_str().unwrap(), "x").await,
        StatusCode::NOT_FOUND,
        "a message id is not a press id"
    );
}

#[tokio::test]
async fn exactly_one_anchor_field_is_required() {
    let w = world().await;
    let alices = addressed_message(&w, &w.alice.1).await;
    let uri = format!("/channels/{}/ephemeral-messages", w.channel);
    let both =
        json!({ "in_reply_to_id": alices["id"], "interaction_id": alices["id"], "content": "x" });
    let neither = json!({ "content": "x" });
    for body in [both, neither] {
        let (status, _) = call(&w, "POST", &uri, &w.bot.1, Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

#[tokio::test]
async fn a_bad_press_id_leaves_the_buttons_untouched_and_unbroadcast() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let uri = format!(
        "/channels/{}/messages/{}/components",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    let (status, _) = call(
        &w,
        "PUT",
        &uri,
        &w.bot.1,
        Some(json!({ "components": [], "interaction_id": Uuid::now_v7().to_string() })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        frame_of_kind(&mut alice, "message.components")
            .await
            .is_none()
    );
    let (_, page) = call(
        &w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    assert_eq!(page[0]["components"], sent["components"]);
}

#[tokio::test]
async fn invisible_characters_and_disguised_links_are_refused() {
    let w = world().await;
    let hidden_label =
        json!([{ "buttons": [{ "label": "Hit\u{202E}", "style": "primary", "custom_id": "a" }] }]);
    let arabic_mark =
        json!([{ "buttons": [{ "label": "Hit\u{061C}", "style": "primary", "custom_id": "a" }] }]);
    let hidden_id =
        json!([{ "buttons": [{ "label": "Hit", "style": "primary", "custom_id": "a\u{200B}b" }] }]);
    let userinfo = json!([{ "buttons": [{ "label": "docs.example.com", "style": "link", "url": "https://docs.example.com@evil.example/x" }] }]);
    let no_host = json!([{ "buttons": [{ "label": "x", "style": "link", "url": "https:///x" }] }]);
    for bad in [hidden_label, arabic_mark, hidden_id, userinfo, no_host] {
        let (status, _) = post_with(&w, &w.bot.1, bad).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let ok = json!([{ "buttons": [{ "label": "Docs", "style": "link", "url": "https://Example.com" }] }]);
    let (status, message) = post_with(&w, &w.bot.1, ok).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        message["components"][0]["buttons"][0]["url"], "https://example.com/",
        "the stored url is the normalized form"
    );
}

#[tokio::test]
async fn invisible_characters_are_refused_when_a_bot_replaces_buttons() {
    let w = world().await;
    let sent = posted(&w).await;
    let uri = format!(
        "/channels/{}/messages/{}/components",
        w.channel,
        sent["id"].as_str().unwrap()
    );
    let control =
        json!([{ "buttons": [{ "label": "Fine", "style": "primary", "custom_id": "a" }] }]);
    let (status, _) = call(
        &w,
        "PUT",
        &uri,
        &w.bot.1,
        Some(json!({ "components": control })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "sanity: a plain label is accepted");
    for label in ["Hit\u{061C}", "Hit\u{202E}"] {
        let bad =
            json!([{ "buttons": [{ "label": label, "style": "primary", "custom_id": "a" }] }]);
        let (status, _) = call(
            &w,
            "PUT",
            &uri,
            &w.bot.1,
            Some(json!({ "components": bad })),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (_, page) = call(
        &w,
        "GET",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        None,
    )
    .await;
    assert_eq!(page[0]["components"][0]["buttons"][0]["label"], "Fine");
}
