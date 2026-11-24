// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every route that stores words under someone's name asks the message.send
//! permission hook and runs the interceptor chain over all of them (decision
//! 0100): polls, app launches, edits, webhook embeds and labels, bot buttons.

use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
};

use crate::support;
use support::module_hooks_world::{
    HookModule, answering, interceptor, permission_hook, rewrites_to_its_input, when_sent,
};
use support::module_world::{World, world};
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

const SEND: &str = "message.pre_send";
const EDIT: &str = "message.pre_edit";
const BANNED: &str = "badword";

async fn general(w: &World) -> ChannelId {
    w.store.create_channel("general", "text").await.unwrap().id
}

async fn ban_sending(w: &World) {
    w.install_hook_module(HookModule {
        id: "gate",
        wasm: answering(&json!({ "allow": false, "reason": "posting is paused" })),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
}

/// A word filter in block mode, on send and on edit.
async fn install_blocker(w: &World) {
    let reject = json!({ "action": "reject", "reason": "that word" });
    w.install_hook_module(HookModule {
        id: "blocker",
        wasm: when_sent(BANNED, &reject, &json!({ "action": "allow" })),
        hooks: vec![
            interceptor(SEND, "reject", &["content"]),
            interceptor(EDIT, "reject", &["content"]),
        ],
    })
    .await;
}

/// A word filter in mask mode: any text holding the word becomes `masked`.
async fn install_masker(w: &World) {
    w.install_hook_module(HookModule {
        id: "masker",
        wasm: when_sent(BANNED, &json!({ "content": "masked" }), &json!({})),
        hooks: vec![
            interceptor(SEND, "rewrite", &["content"]),
            interceptor(EDIT, "rewrite", &["content"]),
        ],
    })
    .await;
}

#[track_caller]
fn refused(status: u16, body: &Value, why: &str) {
    assert_eq!(status, 403, "{body}");
    let error = body["error"].as_str().unwrap_or_default();
    assert!(error.contains(why), "{error}");
}

fn poll(content: &str, question: &str, options: &[&str]) -> Value {
    json!({
        "id": MessageId::generate().to_string(),
        "content": content,
        "question": question,
        "options": options,
    })
}

async fn create_poll(w: &World, channel: ChannelId, body: Value) -> (u16, Value) {
    w.call_json("POST", &format!("/channels/{channel}/messages/polls"), body)
        .await
}

/// Installs `widget`, an app nia may launch.
async fn install_app(w: &World) {
    let wasm = canned_ok_wasm("done");
    let sha256 = sha256_hex(&wasm);
    let point = |kind, command| ModuleExtensionPointSpec {
        kind,
        name: "surf",
        description: None,
        permission: Some("play"),
        command,
        language: None,
    };
    w.store
        .install_module_with_artifact(
            InstallModuleRequest {
                id: "widget",
                name: "Widget",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[ModulePermissionSpec {
                    key: "play",
                    name: "Play",
                    description: "launch it",
                }],
                extension_points: &[point("command", None), point("app", Some("surf"))],
            },
            &wasm,
        )
        .await
        .unwrap();
    w.store.set_module_enabled("widget", true).await.unwrap();
    let role = w
        .store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, "widget", "play")
        .await
        .unwrap();
}

async fn launch(w: &World, channel: ChannelId, caption: &str) -> (u16, Value) {
    let body = json!({
        "id": MessageId::generate().to_string(),
        "content": caption,
        "module_id": "widget",
        "command": "surf",
    });
    w.call_json("POST", &format!("/channels/{channel}/messages/apps"), body)
        .await
}

async fn webhook(w: &World, channel: ChannelId) -> String {
    let minted = w
        .store
        .create_webhook(channel, "alerts", w.user.id)
        .await
        .unwrap();
    format!("/webhooks/{}/{}?wait=true", minted.webhook.id, minted.token)
}

async fn bot(w: &World) -> (UserId, String) {
    let created = w
        .store
        .create_bot("helper", "Helper", Permissions::NONE, w.user.id)
        .await
        .unwrap();
    (created.bot.user_id, created.token)
}

fn buttons(label: &str) -> Value {
    json!([{ "buttons": [{ "label": label, "style": "primary", "custom_id": "go" }] }])
}

async fn only_message(w: &World, channel: ChannelId) -> Value {
    let all = w.list_messages_json(channel).await;
    assert_eq!(all.len(), 1, "{all:?}");
    all.into_iter().next().unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_ban_also_stops_a_poll() {
    let w = world("slimm-paths-ban-poll").await;
    let channel = general(&w).await;
    ban_sending(&w).await;
    let (status, body) = create_poll(&w, channel, poll("", "lunch?", &["yes", "no"])).await;
    refused(status, &body, "posting is paused");
    assert!(w.list_messages_json(channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_ban_also_stops_an_app_launch() {
    let w = world("slimm-paths-ban-app").await;
    let channel = general(&w).await;
    install_app(&w).await;
    ban_sending(&w).await;
    let (status, body) = launch(&w, channel, "come play").await;
    refused(status, &body, "posting is paused");
    assert!(w.list_messages_json(channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_ban_also_stops_an_edit() {
    let w = world("slimm-paths-ban-edit").await;
    let channel = general(&w).await;
    let (_, sent) = w.say(channel, "before").await;
    ban_sending(&w).await;
    let (status, body) = w.edit(channel, sent["id"].as_str().unwrap(), "after").await;
    refused(status, &body, "posting is paused");
    assert_eq!(only_message(&w, channel).await["content"], "before");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_ban_also_stops_a_webhook_post() {
    let w = world("slimm-paths-ban-webhook").await;
    let channel = general(&w).await;
    let path = webhook(&w, channel).await;
    ban_sending(&w).await;
    let (status, body) = w
        .call_json("POST", &path, json!({ "content": "deploy done" }))
        .await;
    refused(status, &body, "posting is paused");
    assert!(w.list_messages_json(channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_ban_also_stops_a_bot_changing_its_buttons() {
    let w = world("slimm-paths-ban-buttons").await;
    let channel = general(&w).await;
    let (_, token) = bot(&w).await;
    let send = json!({
        "id": MessageId::generate().to_string(),
        "content": "pick one",
        "components": buttons("Go"),
    });
    let uri = format!("/channels/{channel}/messages");
    let (status, sent) = w.call_json_as(&token, ("POST", &uri), send).await;
    assert_eq!(status, 200, "{sent}");
    ban_sending(&w).await;
    let uri = format!("{uri}/{}/components", sent["id"].as_str().unwrap());
    let change = json!({ "components": buttons("Gone") });
    let (status, body) = w.call_json_as(&token, ("PUT", &uri), change).await;
    refused(status, &body, "posting is paused");
    let stored = only_message(&w, channel).await;
    assert_eq!(stored["components"][0]["buttons"][0]["label"], "Go");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_reads_a_polls_caption_question_and_options() {
    let w = world("slimm-paths-filter-poll").await;
    let channel = general(&w).await;
    install_blocker(&w).await;
    for body in [
        poll(BANNED, "lunch?", &["yes", "no"]),
        poll("", BANNED, &["yes", "no"]),
        poll("", "lunch?", &["yes", BANNED]),
    ] {
        let (status, answer) = create_poll(&w, channel, body).await;
        refused(status, &answer, "that word");
    }
    assert!(w.list_messages_json(channel).await.is_empty());
    let (status, body) = create_poll(&w, channel, poll("", "lunch?", &["yes", "no"])).await;
    assert_eq!(status, 200, "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_masks_a_poll_and_an_app_caption() {
    let w = world("slimm-paths-mask-poll").await;
    let channel = general(&w).await;
    install_app(&w).await;
    install_masker(&w).await;
    let (status, body) = create_poll(&w, channel, poll(BANNED, BANNED, &["ok", BANNED])).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["content"], "masked");
    assert_eq!(body["poll"]["question"], "masked");
    let options: Vec<&str> = body["poll"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["label"].as_str().unwrap())
        .collect();
    assert_eq!(options, ["ok", "masked"]);
    let (status, body) = launch(&w, channel, BANNED).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["content"], "masked");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_reads_an_app_launch_caption() {
    let w = world("slimm-paths-filter-app").await;
    let channel = general(&w).await;
    install_app(&w).await;
    install_blocker(&w).await;
    let (status, body) = launch(&w, channel, &format!("say {BANNED}")).await;
    refused(status, &body, "that word");
    assert!(w.list_messages_json(channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_reads_webhook_embeds_and_the_username_label() {
    let w = world("slimm-paths-filter-webhook").await;
    let channel = general(&w).await;
    let path = webhook(&w, channel).await;
    install_blocker(&w).await;
    for body in [
        json!({ "embeds": [{ "title": BANNED }] }),
        json!({ "embeds": [{ "fields": [{ "name": "build", "value": BANNED }] }] }),
        json!({ "embeds": [{ "footer": { "text": BANNED } }] }),
        json!({ "content": "deploy done", "username": BANNED }),
    ] {
        let (status, answer) = w.call_json("POST", &path, body).await;
        refused(status, &answer, "that word");
    }
    assert!(w.list_messages_json(channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_masks_webhook_embeds_and_the_username_label() {
    let w = world("slimm-paths-mask-webhook").await;
    let channel = general(&w).await;
    let path = webhook(&w, channel).await;
    install_masker(&w).await;
    let body = json!({
        "username": BANNED,
        "embeds": [{ "title": "ok", "description": BANNED, "author": { "name": BANNED } }],
    });
    let (status, answer) = w.call_json("POST", &path, body).await;
    assert_eq!(status, 200, "{answer}");
    let stored = only_message(&w, channel).await;
    assert_eq!(stored["webhook_username"], "masked");
    let embed = &stored["embeds"][0];
    assert_eq!(embed["title"], "ok");
    assert_eq!(embed["description"], "masked");
    assert_eq!(embed["author_name"], "masked");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_word_filter_masks_a_bots_embeds_and_buttons_on_send_edit_and_change() {
    let w = world("slimm-paths-mask-bot").await;
    let channel = general(&w).await;
    let (_, token) = bot(&w).await;
    install_masker(&w).await;
    let uri = format!("/channels/{channel}/messages");
    let send = json!({
        "id": MessageId::generate().to_string(),
        "content": "pick one",
        "embeds": [{ "title": BANNED }],
        "components": buttons(BANNED),
    });
    let (status, sent) = w.call_json_as(&token, ("POST", &uri), send).await;
    assert_eq!(status, 200, "{sent}");
    assert_eq!(sent["embeds"][0]["title"], "masked");
    assert_eq!(sent["components"][0]["buttons"][0]["label"], "masked");

    let message = format!("{uri}/{}", sent["id"].as_str().unwrap());
    let edit = json!({ "content": "pick again", "embeds": [{ "description": BANNED }] });
    let (status, edited) = w.call_json_as(&token, ("PATCH", &message), edit).await;
    assert_eq!(status, 200, "{edited}");
    assert_eq!(edited["embeds"][0]["description"], "masked");

    let change = json!({ "components": buttons(&format!("no {BANNED}")) });
    let components = format!("{message}/components");
    let (status, changed) = w.call_json_as(&token, ("PUT", &components), change).await;
    assert_eq!(status, 200, "{changed}");
    assert_eq!(changed["components"][0]["buttons"][0]["label"], "masked");
    let stored = only_message(&w, channel).await;
    assert_eq!(stored["components"][0]["buttons"][0]["label"], "masked");
    assert_eq!(stored["embeds"][0]["description"], "masked");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_retried_send_cannot_add_embeds_the_filter_never_read() {
    let w = world("slimm-paths-retry-embeds").await;
    let channel = general(&w).await;
    let (_, token) = bot(&w).await;
    install_blocker(&w).await;
    let uri = format!("/channels/{channel}/messages");
    let id = MessageId::generate().to_string();
    let first = json!({ "id": id, "content": "status" });
    let (status, body) = w.call_json_as(&token, ("POST", &uri), first).await;
    assert_eq!(status, 200, "{body}");
    let retry = json!({ "id": id, "content": "status", "embeds": [{ "title": BANNED }] });
    let (status, body) = w.call_json_as(&token, ("POST", &uri), retry).await;
    refused(status, &body, "that word");
    assert_eq!(only_message(&w, channel).await["embeds"], json!([]));
}

#[tokio::test(flavor = "multi_thread")]
async fn pre_edit_is_told_which_message_the_edit_replies_to() {
    let w = world("slimm-paths-edit-reply").await;
    let channel = general(&w).await;
    let (_, parent) = w.say(channel, "question").await;
    let parent_id = parent["id"].as_str().unwrap();
    let reply = json!({
        "id": MessageId::generate().to_string(),
        "content": "answer",
        "reply_to_id": parent_id,
    });
    let (status, sent) = w
        .call_json("POST", &format!("/channels/{channel}/messages"), reply)
        .await;
    assert_eq!(status, 200, "{sent}");
    w.install_hook_module(HookModule {
        id: "echo",
        wasm: rewrites_to_its_input(),
        hooks: vec![interceptor(EDIT, "rewrite", &["reply_to_id"])],
    })
    .await;
    let (status, edited) = w
        .edit(channel, sent["id"].as_str().unwrap(), "better answer")
        .await;
    assert_eq!(status, 200, "{edited}");
    let seen = edited["content"].as_str().unwrap();
    assert!(seen.contains(parent_id), "{seen}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_call_record_poll_or_app_launch_cannot_be_edited() {
    let w = world("slimm-paths-edit-kind").await;
    let channel = general(&w).await;
    install_app(&w).await;
    let (_, polled) = create_poll(&w, channel, poll("", "lunch?", &["yes", "no"])).await;
    let (_, launched) = launch(&w, channel, "").await;
    let (call, _) = w
        .store
        .record_call(channel, w.user.id, "timed_out", None)
        .await
        .unwrap();
    let call_id = call.message.id.to_string();
    for id in [
        polled["id"].as_str().unwrap(),
        launched["id"].as_str().unwrap(),
        &call_id,
    ] {
        let (status, body) = w.edit(channel, id, "rewritten").await;
        assert_eq!(status, 400, "{body}");
    }
    let rewritten = w
        .list_messages_json(channel)
        .await
        .into_iter()
        .filter(|m| m["content"] == "rewritten")
        .count();
    assert_eq!(rewritten, 0);
    let (_, plain) = w.say(channel, "plain").await;
    let (status, body) = w
        .edit(channel, plain["id"].as_str().unwrap(), "fixed")
        .await;
    assert_eq!(status, 200, "{body}");
}
