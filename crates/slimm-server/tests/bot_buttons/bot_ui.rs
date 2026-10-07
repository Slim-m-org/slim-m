// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Message menu entries and call controls a bot registers, and the use of them,
//! which rides the same interaction machinery as a button.
//! See docs/decisions/0045-bot-contributed-ui.md.

use super::*;
use slimm_server::ids::RoleId;

fn registration() -> Value {
    json!({
        "message_menu": [
            { "id": "translate", "label": "Translate" },
            { "id": "mods", "label": "Report to mods", "permission": Permissions::MANAGE_MESSAGES.bits() }
        ],
        "call_controls": [
            { "id": "pause", "label": "Pause", "icon": "pause" },
            { "id": "skip", "label": "Skip", "icon": "skip_next" }
        ]
    })
}

pub(super) async fn register(w: &World, token: &str, body: Value) -> StatusCode {
    call(w, "PUT", "/bots/ui", token, Some(body)).await.0
}

pub(super) async fn listed(w: &World, channel: ChannelId, token: &str) -> Value {
    let (status, body) = call(
        w,
        "GET",
        &format!("/channels/{channel}/bot-ui"),
        token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    body
}

pub(super) async fn use_entry(
    w: &World,
    channel: ChannelId,
    token: &str,
    body: Value,
) -> (StatusCode, String) {
    let id = Uuid::now_v7().to_string();
    let mut body = body;
    body["id"] = json!(id);
    let (status, _) = call(
        w,
        "POST",
        &format!("/channels/{channel}/bot-ui/{}/interactions", w.bot.0),
        token,
        Some(body),
    )
    .await;
    (status, id)
}

fn menu_use(entry: &str, message: &Value) -> Value {
    json!({ "surface": "message_menu", "entry_id": entry, "message_id": message["id"] })
}

fn control_use(entry: &str) -> Value {
    json!({ "surface": "call_control", "entry_id": entry })
}

pub(super) async fn voice_channel(w: &World) -> ChannelId {
    w.state
        .store
        .create_channel("call", "voice")
        .await
        .unwrap()
        .id
}

async fn plain_message(w: &World) -> Value {
    call(
        w,
        "POST",
        &format!("/channels/{}/messages", w.channel),
        &w.bob.1,
        Some(json!({ "id": Uuid::now_v7().to_string(), "content": "hi" })),
    )
    .await
    .1
}

#[tokio::test]
async fn only_a_bot_registers_and_a_bad_set_changes_nothing() {
    let w = world().await;
    assert_eq!(
        register(&w, &w.alice.1, registration()).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        register(&w, &w.bot.1, registration()).await,
        StatusCode::NO_CONTENT
    );
    let too_many: Vec<Value> = (0..6)
        .map(|i| json!({ "id": format!("e{i}"), "label": "x" }))
        .collect();
    let spoofed = json!({ "message_menu": [{ "id": "a", "label": "Cancel\u{202E}gnihtemos" }] });
    for bad in [json!({ "message_menu": too_many }), spoofed] {
        assert_eq!(register(&w, &w.bot.1, bad).await, StatusCode::BAD_REQUEST);
    }
    let bots = listed(&w, w.channel, &w.bob.1).await;
    assert_eq!(bots[0]["message_menu"].as_array().unwrap().len(), 1);
    assert_eq!(bots[0]["call_controls"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn a_registration_tells_every_connection_which_bot_changed() {
    let w = world().await;
    let addr = serve(w.state.clone()).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    assert_eq!(
        register(&w, &w.bot.1, registration()).await,
        StatusCode::NO_CONTENT
    );
    let frame = frame_of_kind(&mut bob, "bot_ui.changed")
        .await
        .expect("a connected member hears that the bot's controls changed");
    assert_eq!(frame["bot_user_id"], w.bot.0.to_string());

    assert_eq!(
        register(&w, &w.bob.1, registration()).await,
        StatusCode::FORBIDDEN
    );
    assert!(
        frame_of_kind(&mut bob, "bot_ui.changed").await.is_none(),
        "a refused registration announces nothing"
    );
}

#[tokio::test]
async fn a_registration_replaces_the_last_whole() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let only = json!({ "call_controls": [{ "id": "stop", "label": "Stop", "icon": "stop" }] });
    register(&w, &w.bot.1, only).await;
    let bots = listed(&w, w.channel, &w.bob.1).await;
    assert!(bots[0]["message_menu"].as_array().unwrap().is_empty());
    assert_eq!(bots[0]["call_controls"][0]["id"], "stop");
}

#[tokio::test]
async fn an_entry_that_names_a_permission_is_hidden_from_a_member_without_it() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let bots = listed(&w, w.channel, &w.alice.1).await;
    let ids: Vec<&str> = bots[0]["message_menu"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["translate"]);
    let sent = plain_message(&w).await;
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu_use("mods", &sent)).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "gated on use, not only shown"
    );
}

#[tokio::test]
async fn a_bot_that_cannot_see_the_channel_offers_nothing_there() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let hidden = w
        .state
        .store
        .create_channel("hidden", "text")
        .await
        .unwrap();
    let everyone = w
        .state
        .store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_everyone)
        .unwrap();
    w.state
        .store
        .set_role_overwrite(
            hidden.id,
            RoleId(everyone.id.0),
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    assert_eq!(listed(&w, hidden.id, &w.alice.1).await, json!([]));
    let sent = plain_message(&w).await;
    let (status, _) = use_entry(&w, hidden.id, &w.alice.1, menu_use("translate", &sent)).await;
    assert_ne!(status, StatusCode::OK);
}

#[tokio::test]
async fn using_a_menu_entry_reaches_only_that_bot_with_the_target_and_the_member() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let sent = plain_message(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let mut rival = connect(&w, addr, &w.other_bot.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let (status, id) = use_entry(&w, w.channel, &w.alice.1, menu_use("translate", &sent)).await;
    assert_eq!(status, StatusCode::OK);
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the owning bot hears it");
    assert_eq!(frame["interaction_id"], id);
    assert_eq!(frame["kind"], "message_menu");
    assert_eq!(frame["custom_id"], "translate");
    assert_eq!(frame["message_id"], sent["id"]);
    assert_eq!(frame["user_id"], w.alice.0.to_string());
    for (who, ws) in [("another bot", &mut rival), ("another member", &mut bob)] {
        assert!(
            frame_of_kind(ws, "interaction.created").await.is_none(),
            "{who} must not hear it"
        );
    }

    let whisper_status = whisper(&w, &w.bot.1, &id, "guten tag").await;
    assert_eq!(whisper_status, StatusCode::OK, "a private reply answers it");
}

#[tokio::test]
async fn a_menu_entry_needs_a_registered_id_a_real_message_and_a_member() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let sent = plain_message(&w).await;
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu_use("nope", &sent)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let ghost = json!({ "id": Uuid::now_v7().to_string() });
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu_use("translate", &ghost)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let no_target = json!({ "surface": "message_menu", "entry_id": "translate" });
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, no_target).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = use_entry(&w, w.channel, &w.other_bot.1, menu_use("translate", &sent)).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "bots cannot drive each other"
    );
}

#[tokio::test]
async fn a_call_control_needs_a_voice_channel_and_a_member_on_the_call() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let call_channel = voice_channel(&w).await;
    let (status, _) = use_entry(&w, call_channel, &w.alice.1, control_use("pause")).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "viewing is not being on the call"
    );

    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice.0, call_channel);
    let (status, _) = use_entry(&w, call_channel, &w.alice.1, control_use("pause")).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "the bot is not on the call");

    w.state
        .voice
        .record_heartbeat_reporting_new(w.bot.0, call_channel);
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let (status, id) = use_entry(&w, call_channel, &w.alice.1, control_use("pause")).await;
    assert_eq!(status, StatusCode::OK);
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the bot hears it");
    assert_eq!(frame["kind"], "call_control");
    assert_eq!(frame["custom_id"], "pause");
    assert_eq!(frame["interaction_id"], id);
    assert!(frame.get("message_id").is_none(), "a call has no message");

    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice.0, w.channel);
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, control_use("pause")).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "a text channel has no call");
}

#[tokio::test]
async fn a_retried_use_is_the_same_use_and_an_ack_clears_it() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let call_channel = voice_channel(&w).await;
    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice.0, call_channel);
    w.state
        .voice
        .record_heartbeat_reporting_new(w.bot.0, call_channel);
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;

    let id = Uuid::now_v7().to_string();
    let uri = format!("/channels/{call_channel}/bot-ui/{}/interactions", w.bot.0);
    let body = json!({ "id": id, "surface": "call_control", "entry_id": "skip" });
    for _ in 0..2 {
        let (status, _) = call(&w, "POST", &uri, &w.alice.1, Some(body.clone())).await;
        assert_eq!(status, StatusCode::OK);
    }
    assert!(
        frame_of_kind(&mut bot, "interaction.created")
            .await
            .is_some()
    );
    assert!(
        frame_of_kind(&mut bot, "interaction.created")
            .await
            .is_none(),
        "a retry is not a second use"
    );

    let (status, _) = call(
        &w,
        "POST",
        &format!("/channels/{call_channel}/interactions/{id}/ack"),
        &w.bot.1,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let answered = frame_of_kind(&mut alice, "interaction.answered")
        .await
        .expect("the member hears the answer");
    assert!(answered.get("message_id").is_none());
}

#[tokio::test]
async fn a_bot_with_two_live_tokens_lists_each_entry_once() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect(&format!("sqlite://{}", w.db_path))
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO bot_tokens (token_hash, bot_user_id, session_id, name, created_by, created_at)
         SELECT 'second-token', bot_user_id, session_id, name, created_by, created_at
         FROM bot_tokens WHERE bot_user_id = ?",
    )
    .bind(w.bot.0)
    .execute(&pool)
    .await
    .unwrap();
    let bots = listed(&w, w.channel, &w.bob.1).await;
    assert_eq!(bots.as_array().unwrap().len(), 1);
    assert_eq!(bots[0]["message_menu"].as_array().unwrap().len(), 1);
    assert_eq!(bots[0]["call_controls"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn a_bot_removed_from_the_space_cannot_be_used() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let sent = plain_message(&w).await;
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu_use("translate", &sent)).await;
    assert_eq!(status, StatusCode::OK);
    w.state
        .store
        .remove_from_space(w.bot.0, w.bob.0, None)
        .await
        .unwrap();
    let (status, _) = use_entry(&w, w.channel, &w.alice.1, menu_use("translate", &sent)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn reusing_a_use_id_for_anything_different_is_a_conflict() {
    let w = world().await;
    register(&w, &w.bot.1, registration()).await;
    let sent = plain_message(&w).await;
    let other = plain_message(&w).await;
    let id = Uuid::now_v7().to_string();
    let uri = format!("/channels/{}/bot-ui/{}/interactions", w.channel, w.bot.0);
    let body = |entry: &str, message: &Value| json!({ "id": id, "surface": "message_menu", "entry_id": entry, "message_id": message["id"] });
    let (status, _) = call(&w, "POST", &uri, &w.alice.1, Some(body("translate", &sent))).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&w, "POST", &uri, &w.alice.1, Some(body("translate", &sent))).await;
    assert_eq!(status, StatusCode::OK, "the same use is idempotent");
    let (status, _) = call(&w, "POST", &uri, &w.alice.1, Some(body("mods", &sent))).await;
    assert_ne!(status, StatusCode::OK, "another entry under the same id");
    let (status, _) = call(
        &w,
        "POST",
        &uri,
        &w.alice.1,
        Some(body("translate", &other)),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "another message under the same id"
    );
}
