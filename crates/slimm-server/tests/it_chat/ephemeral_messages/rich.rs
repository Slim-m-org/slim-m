// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Attachments ride by existing id and embeds ride inline on a private answer.
//! See docs/decisions/0037-ephemeral-bot-messages.md.

use super::*;

const FILE: [u8; 32] = [7; 32];

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

async fn stored_file(w: &World, uploader: UserId, sha: [u8; 32]) {
    w.state
        .store
        .store_attachment(&sha, 12, "image/png", "chart.png", Some(uploader))
        .await
        .unwrap();
}

/// A message from alice that puts `sha` on the channel, so anyone who can view it may fetch.
async fn publish_file(w: &World, sha: [u8; 32]) -> Value {
    let (status, body) = call(
        w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        &w.alice.1,
        Some(json!({
            "id": Uuid::now_v7().to_string(),
            "content": "!balance",
            "attachment_ids": [hex(&sha)],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    body
}

async fn whisper_with(w: &World, anchor: &Value, extra: Value) -> (StatusCode, Value) {
    let mut body = json!({ "in_reply_to_id": anchor["id"], "content": "here" });
    body.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    call(
        w,
        "POST",
        &format!("/channels/{}/ephemeral-messages", w.channel),
        &w.bot.1,
        Some(body),
    )
    .await
}

#[tokio::test]
async fn a_file_already_on_the_channel_and_an_embed_reach_the_recipient() {
    let w = world().await;
    stored_file(&w, w.alice.0, FILE).await;
    let anchor = publish_file(&w, FILE).await;
    let addr = serve(w.state.clone()).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;

    let extra = json!({
        "attachment_ids": [hex(&FILE)],
        "embeds": [{ "title": "Balance", "description": "500 chips", "color": 0x2E_A043 }],
    });
    let (status, sent) = whisper_with(&w, &anchor, extra).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sent["attachments"][0]["id"], hex(&FILE));
    assert_eq!(sent["attachments"][0]["filename"], "chart.png");
    assert_eq!(sent["embeds"][0]["title"], "Balance");
    assert_eq!(sent["embeds"][0]["accent"], "green");

    let frame = frame_of_kind(&mut alice, "message.ephemeral")
        .await
        .expect("the recipient hears it");
    assert_eq!(frame["message"]["attachments"], sent["attachments"]);
    assert_eq!(frame["message"]["embeds"], sent["embeds"]);
}

#[tokio::test]
async fn an_embed_alone_is_a_complete_private_message() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let extra = json!({ "content": "", "embeds": [{ "title": "Only an embed" }] });
    let (status, sent) = whisper_with(&w, &anchor, extra).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sent["content"], "");
    assert_eq!(sent["attachments"], json!([]));

    let (status, _) = whisper_with(&w, &anchor, json!({ "content": "" })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_message_without_either_keeps_the_old_shape_plus_empty_lists() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let (status, sent) = whisper_with(&w, &anchor, json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sent["attachments"], json!([]));
    assert_eq!(sent["embeds"], json!([]));
}

#[tokio::test]
async fn a_file_the_recipient_could_not_already_fetch_is_refused() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let only_bot = [1; 32];
    let only_alice = [2; 32];
    let unknown = [3; 32];
    stored_file(&w, w.bot.0, only_bot).await;
    stored_file(&w, w.alice.0, only_alice).await;

    for sha in [only_bot, only_alice, unknown] {
        let extra = json!({ "attachment_ids": [hex(&sha)] });
        let (status, _) = whisper_with(&w, &anchor, extra).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{}", hex(&sha));
    }
}

#[tokio::test]
async fn a_refused_attachment_costs_no_budget_and_the_caps_hold() {
    let w = world().await;
    let anchor = say(&w, &w.alice.1, w.channel, "!balance").await;
    let extra = json!({ "attachment_ids": [hex(&[9; 32])] });
    for _ in 0..4 {
        let (status, _) = whisper_with(&w, &anchor, extra.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, _) = whisper_with(&w, &anchor, json!({})).await;
    assert_eq!(status, StatusCode::OK, "refusals must not spend the budget");

    let many = vec![json!({ "title": "x" }); 11];
    let (status, _) = whisper_with(&w, &anchor, json!({ "embeds": many })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let malformed = json!({ "attachment_ids": ["nothex"] });
    let (status, _) = whisper_with(&w, &anchor, malformed).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_bot_needs_attach_files_to_send_one() {
    let w = world().await;
    stored_file(&w, w.alice.0, FILE).await;
    let anchor = publish_file(&w, FILE).await;
    let channel = w.channel;
    w.state
        .store
        .set_member_overwrite(
            channel,
            w.bot.0,
            Permissions::NONE,
            Permissions::ATTACH_FILES,
        )
        .await
        .expect("deny attach for the bot");
    let extra = json!({ "attachment_ids": [hex(&FILE)] });
    let (status, _) = whisper_with(&w, &anchor, extra).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = whisper_with(&w, &anchor, json!({})).await;
    assert_eq!(status, StatusCode::OK);
}
