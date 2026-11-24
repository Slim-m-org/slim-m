// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A timeout reaches the bot surfaces: a timed-out member cannot drive a bot,
//! and a timed-out bot cannot put new text in front of members.

use super::bot_ui::{listed, register, use_entry};
use super::*;

const HOUR_MS: i64 = 60 * 60 * 1000;

async fn time_out(w: &World, user: UserId) {
    w.state
        .store
        .set_member_timeout(user, support::totp_clock::now_ms() + HOUR_MS, None, user)
        .await
        .unwrap();
}

fn assert_timed_out(status: StatusCode, body: &Value, what: &str) {
    assert_eq!(status, StatusCode::FORBIDDEN, "{what}: {body}");
    assert_eq!(body["code"], "timed_out", "{what}: {body}");
}

fn form() -> Value {
    json!({
        "custom_id": "ticket",
        "title": "Open a ticket",
        "fields": [{ "custom_id": "what", "label": "What" }]
    })
}

fn interaction_uri(w: &World, id: &str, verb: &str) -> String {
    format!("/channels/{}/interactions/{id}/{verb}", w.channel)
}

#[tokio::test]
async fn a_timed_out_member_cannot_press_a_button_or_submit_a_form() {
    let w = world().await;
    let sent = posted(&w).await;
    let (status, _, press_id) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_eq!(status, StatusCode::OK);
    let uri = interaction_uri(&w, &press_id, "form");
    let (status, _) = call(&w, "POST", &uri, &w.bot.1, Some(form())).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    time_out(&w, w.alice.0).await;
    let (status, body, _) = press(&w, &w.alice.1, &sent, "hit").await;
    assert_timed_out(status, &body, "a press");
    let answers = json!({ "id": Uuid::now_v7().to_string(), "fields": { "what": "words" } });
    let uri = interaction_uri(&w, &press_id, "submit");
    let (status, body) = call(&w, "POST", &uri, &w.alice.1, Some(answers)).await;
    assert_timed_out(status, &body, "a form submission");
}

#[tokio::test]
async fn a_timed_out_member_cannot_use_a_bot_menu_entry() {
    let w = world().await;
    let entries = json!({ "message_menu": [{ "id": "translate", "label": "Translate" }] });
    assert_eq!(
        register(&w, &w.bot.1, entries).await,
        StatusCode::NO_CONTENT
    );
    let sent = posted(&w).await;
    time_out(&w, w.alice.0).await;

    let menu =
        json!({ "surface": "message_menu", "entry_id": "translate", "message_id": sent["id"] });
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_timed_out_bot_cannot_open_a_form() {
    let w = world().await;
    let sent = posted(&w).await;
    let (_, _, press_id) = press(&w, &w.alice.1, &sent, "hit").await;
    time_out(&w, w.bot.0).await;

    let uri = interaction_uri(&w, &press_id, "form");
    let (status, body) = call(&w, "POST", &uri, &w.bot.1, Some(form())).await;
    assert_timed_out(status, &body, "opening a form");
}

/// A bot re-registers on every connect, so the write is kept and only hidden.
#[tokio::test]
async fn a_timed_out_bots_menu_and_commands_are_hidden_until_it_lifts() {
    let w = world().await;
    time_out(&w, w.bot.0).await;
    let entries = json!({ "message_menu": [{ "id": "translate", "label": "Translate" }] });
    assert_eq!(
        register(&w, &w.bot.1, entries).await,
        StatusCode::NO_CONTENT
    );
    let commands =
        json!({ "prefix": "!", "commands": [{ "name": "roll", "description": "Roll" }] });
    let (status, _) = call(&w, "PUT", "/bots/commands", &w.bot.1, Some(commands)).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert_eq!(listed(&w, w.channel, &w.alice.1).await, json!([]));
    let uri = format!("/channels/{}/bot-commands", w.channel);
    let (status, listed_commands) = call(&w, "GET", &uri, &w.alice.1, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(listed_commands, json!([]));

    w.state
        .store
        .clear_member_timeout(w.bot.0, w.bot.0)
        .await
        .unwrap();
    assert_eq!(
        listed(&w, w.channel, &w.alice.1).await[0]["bot_user_id"],
        w.bot.0.to_string()
    );
    let (_, listed_commands) = call(&w, "GET", &uri, &w.alice.1, None).await;
    assert_eq!(listed_commands[0]["name"], "roll");
}
