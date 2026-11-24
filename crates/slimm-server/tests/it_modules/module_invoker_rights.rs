// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's module run is held to that member's own standing: the join gate, a timeout,
//! their own `MENTION_EVERYONE`, and the message.send permission hook.

use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;

use crate::support;
use support::module_hooks_world::{HookModule, answering, permission_hook};
use support::module_world::{Install, World, message_id_in, post_request, world};
use support::wasm_fixtures::{canned_ok_wasm, host_call_loop_wasm};

async fn run(w: &World, module: &str, body: Value) -> (u16, Value) {
    let uri = format!("/modules/{module}/commands/run");
    w.call_json("POST", &uri, body).await
}

async fn install_printer(w: &World, output: &str) {
    w.install(Install {
        id: "printer",
        wasm: canned_ok_wasm(output),
        declared: &[],
        approved_host: &[],
    })
    .await;
}

async fn install_announcer(w: &World, channel: ChannelId, content: &str) {
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post_request(&channel.to_string(), content), 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
}

async fn grant(w: &World, user: UserId, name: &str, permissions: Permissions) {
    let role = w.store.create_role(name, permissions, false).await.unwrap();
    w.store.assign_role(user, role).await.unwrap();
}

async fn texts(w: &World, channel: ChannelId) -> Vec<String> {
    let page = w.store.list_messages(channel, None, 10).await.unwrap();
    page.into_iter().map(|m| m.content).collect()
}

#[tokio::test]
async fn a_member_who_has_not_accepted_the_rules_cannot_run_a_module_command() {
    use sqlx::Connection;
    let w = world("slimm-modrights-pending").await;
    install_printer(&w, "hi").await;
    let mut conn = sqlx::SqliteConnection::connect(&format!("sqlite://{}", w.db_path))
        .await
        .unwrap();
    sqlx::query("INSERT INTO pending_members (user_id, since) VALUES (?, 0)")
        .bind(w.user.id)
        .execute(&mut conn)
        .await
        .unwrap();

    let (status, body) = run(&w, "printer", json!({ "input": "go" })).await;

    assert_eq!(status, 403, "{body}");
    assert_eq!(body["error"], "accept the rules first", "{body}");
}

#[tokio::test]
async fn a_timed_out_member_cannot_run_a_module_command() {
    let w = world("slimm-modrights-timeout").await;
    install_printer(&w, "hi").await;
    let admin = w.store.create_user("root", "Root").await.unwrap();
    let until = support::totp_clock::now_ms() + 3_600_000;
    w.store
        .set_member_timeout(w.user.id, until, None, admin.id)
        .await
        .unwrap();

    let (status, body) = run(&w, "printer", json!({ "input": "go" })).await;

    assert_eq!(status, 403, "{body}");
    assert_eq!(body["code"], "timed_out", "{body}");
}

/// The module's principal may mention everyone; `bob` only watches.
async fn pinging_module(w: &World, module: &str) -> UserId {
    let bot = w.store.ensure_module_bot(module, "Bot").await.unwrap();
    grant(w, bot, "module-pingers", Permissions::MENTION_EVERYONE).await;
    w.store.create_user("bob", "Bob").await.unwrap().id
}

#[tokio::test]
async fn a_post_during_a_members_run_cannot_borrow_the_modules_everyone() {
    let w = world("slimm-modrights-everyone").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    install_announcer(&w, channel, "@everyone heads up").await;
    let bob = pinging_module(&w, "announcer").await;

    let id = message_id_in(&w.answer_in("announcer", Some(channel)).await);

    assert!(!w.store.is_mentioned(id, bob).await.unwrap());
}

#[tokio::test]
async fn a_post_during_a_run_reaches_everyone_when_member_and_module_both_may() {
    let w = world("slimm-modrights-everyone-both").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    install_announcer(&w, channel, "@everyone heads up").await;
    let bob = pinging_module(&w, "announcer").await;
    grant(&w, w.user.id, "pingers", Permissions::MENTION_EVERYONE).await;

    let id = message_id_in(&w.answer_in("announcer", Some(channel)).await);

    assert!(w.store.is_mentioned(id, bob).await.unwrap());
}

async fn deny_sends(w: &World) {
    w.install_hook_module(HookModule {
        id: "gate",
        wasm: answering(&json!({ "allow": false, "reason": "new members wait" })),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_hook_denial_stops_a_modules_post_during_a_members_run() {
    let w = world("slimm-modrights-hook-post").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    install_announcer(&w, channel, "from the module").await;
    deny_sends(&w).await;

    let answer = w.answer_in("announcer", Some(channel)).await;

    assert!(texts(&w, channel).await.is_empty(), "{answer}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_hook_denial_stops_posted_slash_output() {
    let w = world("slimm-modrights-hook-output").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    install_printer(&w, "printed").await;
    deny_sends(&w).await;
    let body = json!({ "input": "go", "channel_id": channel.to_string(), "post_output": true });

    let (status, answer) = run(&w, "printer", body).await;

    assert_eq!(status, 200, "{answer}");
    assert_eq!(answer["ok"], false, "{answer}");
    assert!(texts(&w, channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_denying_hook_slash_output_still_posts() {
    let w = world("slimm-modrights-hook-control").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    install_printer(&w, "printed").await;
    let body = json!({ "input": "go", "channel_id": channel.to_string(), "post_output": true });

    let (_, answer) = run(&w, "printer", body).await;

    assert_eq!(texts(&w, channel).await, vec!["printed"], "{answer}");
}
