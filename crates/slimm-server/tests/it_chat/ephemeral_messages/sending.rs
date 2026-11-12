// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! See docs/decisions/0037-ephemeral-bot-messages.md.

use super::*;

#[tokio::test]
async fn only_the_addressed_members_own_sockets_hear_it() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let addr = serve(w.state.clone()).await;
    let mut phone = connect(&w, addr, &w.alice.1).await;
    let mut desktop = connect(&w, addr, &w.alice.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;
    let mut admin = connect(&w, addr, &w.admin.1).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;

    let (status, sent) = whisper(&w, &w.bot.1, w.channel, &anchor, "you have 500 chips").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sent["author_id"], w.bot.0.to_string());
    assert_eq!(sent["in_reply_to_id"], anchor["id"]);
    assert!(sent.get("seq").is_none(), "it must carry no seq");

    for ws in [&mut phone, &mut desktop] {
        let frame = frame_of_kind(ws, "message.ephemeral")
            .await
            .expect("every device of the addressed member must hear it");
        assert_eq!(frame["message"]["content"], "you have 500 chips");
        assert_eq!(frame["message"]["id"], sent["id"]);
    }
    for (who, ws) in [
        ("bob", &mut bob),
        ("an administrator", &mut admin),
        ("the bot", &mut bot),
    ] {
        assert!(
            frame_of_kind(ws, "message.ephemeral").await.is_none(),
            "{who} must not hear a private message"
        );
    }
}

#[tokio::test]
async fn it_leaves_no_trace_in_history_search_sync_or_seq() {
    let w = world().await;
    let first = say(&w, &w.alice.1, w.channel, "!balance").await;
    assert_eq!(first["seq"], 1);
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &first, "zebrafruit secret").await;
    assert_eq!(status, StatusCode::OK);
    let second = say(&w, &w.bob.1, w.channel, "hello").await;
    assert_eq!(second["seq"], 2, "a private message must leave no gap");

    for token in [&w.alice.1, &w.bob.1, &w.admin.1] {
        let uri = format!("/channels/{}/messages", w.channel);
        let (_, page) = call(&w, "GET", &uri, token, None).await;
        assert!(!page.to_string().contains("zebrafruit"));
        let (_, found) = call(&w, "GET", "/search/messages?q=zebrafruit", token, None).await;
        assert!(!found.to_string().contains("zebrafruit"));
        let scopes = json!({ "scopes": [{ "channel_id": w.channel.to_string(), "after_seq": 0 }] });
        let (_, synced) = call(&w, "POST", "/sync", token, Some(scopes)).await;
        assert!(!synced.to_string().contains("zebrafruit"));
        assert_eq!(synced["scopes"][0]["messages"].as_array().unwrap().len(), 2);
    }
}

#[tokio::test]
async fn a_member_cannot_send_one() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let (status, _) = whisper(&w, &w.bob.1, w.channel, &anchor, "boo").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = whisper(&w, &w.admin.1, w.channel, &anchor, "boo").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_recipient_is_the_anchors_author_and_nobody_else() {
    let w = world().await;
    let other = w
        .state
        .store
        .create_channel("random", "text")
        .await
        .unwrap()
        .id;
    let elsewhere = say(&w, &w.alice.1, other, "!balance").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &elsewhere, "x").await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "an anchor in another channel"
    );

    let unknown = json!({ "id": Uuid::now_v7().to_string() });
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &unknown, "x").await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let own = say(&w, &w.bot.1, w.channel, "public").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &own, "x").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a bot's own message is no anchor"
    );
}

#[tokio::test]
async fn an_old_message_is_no_longer_an_anchor() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    sqlx::query("UPDATE messages SET created_at = created_at - ? WHERE id = ?")
        .bind(slimm_server::ephemeral::ANCHOR_WINDOW_MS + 60_000)
        .bind(Uuid::parse_str(anchor["id"].as_str().unwrap()).unwrap())
        .execute(&w.pool)
        .await
        .unwrap();
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, "late").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_recipient_who_can_no_longer_view_the_channel_is_refused() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    w.state
        .store
        .set_member_overwrite(
            w.channel,
            w.alice.0,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, "x").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn content_is_validated_like_a_message() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, "   ").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, &"x".repeat(4_001)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_member_who_blocked_the_bot_never_hears_it() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    w.state.store.block_user(w.alice.0, w.bot.0).await.unwrap();
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, "x").await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        frame_of_kind(&mut alice, "message.ephemeral")
            .await
            .is_none()
    );
}

#[tokio::test]
async fn a_message_not_addressed_to_the_bot_is_no_anchor() {
    let w = world().await;
    let chatter = say(&w, &w.alice.1, w.channel, "anyone seen the game?").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &chatter, "click here").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let near_miss = say(&w, &w.alice.1, w.channel, "!balancer").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &near_miss, "x").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a prefix alone is not a command"
    );
}

#[tokio::test]
async fn a_mention_or_a_reply_to_the_bot_addresses_it() {
    let w = world().await;
    let mention = say(&w, &w.alice.1, w.channel, "@helper are you there").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &mention, "yes").await;
    assert_eq!(status, StatusCode::OK);

    let bots_own = say(&w, &w.bot.1, w.channel, "what next?").await;
    let (status, reply) = call(
        &w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        &w.bob.1,
        Some(json!({
            "id": Uuid::now_v7().to_string(),
            "content": "the second one",
            "reply_to_id": bots_own["id"],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &reply, "done").await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_bot_gets_three_private_messages_per_anchor() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    for n in 0..slimm_server::ephemeral::MAX_PER_ANCHOR {
        let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, &format!("part {n}")).await;
        assert_eq!(status, StatusCode::OK);
    }
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &anchor, "one too many").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);

    let fresh = say(&w, &w.alice.1, w.channel, "!balance").await;
    let (status, _) = whisper(&w, &w.bot.1, w.channel, &fresh, "a new anchor").await;
    assert_eq!(status, StatusCode::OK);
}
