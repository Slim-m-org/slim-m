// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reporting a private message the server never stored: the reporter's text
//! and the bot's identity land on the ordinary report queue.
//! See docs/decisions/0037-ephemeral-bot-messages.md.

use super::*;

struct Whispered {
    id: String,
    body: Value,
}

async fn whispered(w: &World, text: &str) -> Whispered {
    let anchor = say(w, &w.alice.1, w.channel, "!balance").await;
    let (status, sent) = whisper(w, &w.bot.1, w.channel, &anchor, text).await;
    assert_eq!(status, StatusCode::OK);
    let id = sent["id"].as_str().unwrap().to_owned();
    let body = json!({
        "subject_kind": "ephemeral_message",
        "subject_id": id,
        "channel_id": w.channel.to_string(),
        "author_id": w.bot.0.to_string(),
        "snapshot": text,
        "reason": "it phished me",
    });
    Whispered { id, body }
}

async fn file(w: &World, token: &str, body: Value) -> (StatusCode, Value) {
    call(w, "POST", "/reports", token, Some(body)).await
}

fn with(mut body: Value, key: &str, value: Value) -> Value {
    body[key] = value;
    body
}

#[tokio::test]
async fn a_moderator_sees_the_text_and_the_bot_the_reporter_saw() {
    let w = world().await;
    let m = whispered(&w, "send me your password").await;
    let (status, filed) = file(&w, &w.alice.1, m.body.clone()).await;
    assert_eq!(status, StatusCode::OK);

    let (status, queue) = call(&w, "GET", "/reports", &w.admin.1, None).await;
    assert_eq!(status, StatusCode::OK);
    let report = &queue[0];
    assert_eq!(report["id"], filed["id"]);
    assert_eq!(report["subject_kind"], "ephemeral_message");
    assert_eq!(report["subject_id"], m.id);
    assert_eq!(report["channel_id"], w.channel.to_string());
    assert_eq!(report["snapshot"], "send me your password");
    assert_eq!(report["subject_author_id"], w.bot.0.to_string());
    assert_eq!(report["reporter_id"], w.alice.0.to_string());
}

#[tokio::test]
async fn the_bot_stays_on_the_report_once_it_is_resolved() {
    let w = world().await;
    let m = whispered(&w, "send me your password").await;
    let (_, filed) = file(&w, &w.alice.1, m.body).await;
    let uri = format!("/reports/{}", filed["id"].as_str().unwrap());
    let resolve = Some(json!({ "resolution": "resolved" }));
    let (status, _) = call(&w, "PATCH", &uri, &w.admin.1, resolve).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (_, history) = call(&w, "GET", "/reports/history", &w.admin.1, None).await;
    let item = &history[0];
    assert_eq!(item["subject_kind"], "ephemeral_message");
    assert_eq!(item["snapshot"], "send me your password");
    assert_eq!(item["subject_author_id"], w.bot.0.to_string());
}

#[tokio::test]
async fn a_retry_replays_and_a_second_report_conflicts() {
    let w = world().await;
    let m = whispered(&w, "hello").await;
    let with_id = with(m.body.clone(), "id", json!(Uuid::now_v7().to_string()));
    let (status, first) = file(&w, &w.alice.1, with_id.clone()).await;
    assert_eq!(status, StatusCode::OK);
    let (status, again) = file(&w, &w.alice.1, with_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(first["id"], again["id"]);
    let (status, _) = file(&w, &w.alice.1, m.body).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_claim_that_does_not_hold_up_is_refused() {
    let w = world().await;
    let m = whispered(&w, "hello").await;
    let human = with(m.body.clone(), "author_id", json!(w.bob.0.to_string()));
    let (status, _) = file(&w, &w.alice.1, human).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "only a bot can have sent one"
    );

    let unknown = with(
        m.body.clone(),
        "channel_id",
        json!(Uuid::now_v7().to_string()),
    );
    let (status, _) = file(&w, &w.alice.1, unknown).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, _) = file(
        &w,
        &w.alice.1,
        with(m.body.clone(), "snapshot", json!("  ")),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let long = with(m.body.clone(), "snapshot", json!("x".repeat(4001)));
    let (status, _) = file(&w, &w.alice.1, long).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let mut partial = m.body.clone();
    partial.as_object_mut().unwrap().remove("author_id");
    let (status, _) = file(&w, &w.alice.1, partial).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let stray = with(m.body, "subject_kind", json!("user"));
    let (status, _) = file(&w, &w.alice.1, stray).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_member_who_cannot_view_the_channel_cannot_report_into_it() {
    let w = world().await;
    let m = whispered(&w, "hello").await;
    w.state
        .store
        .set_member_overwrite(
            w.channel,
            w.bob.0,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let (status, _) = file(&w, &w.bob.1, m.body).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, queue) = call(&w, "GET", "/reports", &w.admin.1, None).await;
    assert_eq!(queue.as_array().unwrap().len(), 0);
}
