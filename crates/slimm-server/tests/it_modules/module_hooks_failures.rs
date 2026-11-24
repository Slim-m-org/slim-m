// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a failing hook leaves behind: no module text, no unchecked sends past a
//! fail-closed hook, an audit row for the server's own disables, per-hook stats.

use serde_json::{Value, json};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{HookChange, HookKind};

use crate::support;
use support::module_hooks_world::{HookModule, answering, interceptor, trapping};
use support::module_world::{World, world};
use support::wasm_fixtures::canned_raw_wasm;

const SEND: &str = "message.pre_send";
const EDIT: &str = "message.pre_edit";
const SECRET: &str = "dm-text-the-module-echoed";

async fn general(w: &World) -> ChannelId {
    w.store.create_channel("general", "text").await.unwrap().id
}

async fn admin_token(w: &World) -> String {
    let admin = w.store.create_user("boss", "Boss").await.unwrap();
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    w.store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token
}

async fn admin_call(
    w: &World,
    token: &str,
    method: &str,
    uri: &str,
    body: Option<Value>,
) -> (u16, Value) {
    let request = support::app::request(method, uri, Some(token), body);
    let response = tower::ServiceExt::oneshot(w.router.clone(), request)
        .await
        .unwrap();
    let status = response.status().as_u16();
    (status, support::app::json_body_or_null(response).await)
}

fn echoing_error() -> Vec<u8> {
    canned_raw_wasm(
        json!({ "ok": false, "error": SECRET })
            .to_string()
            .as_bytes(),
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hooks_own_failure_text_is_never_stored_or_shown() {
    let w = world("slimm-hooks-no-text").await;
    let channel = general(&w).await;
    let token = admin_token(&w).await;
    w.install_hook_module(HookModule {
        id: "echo",
        wasm: echoing_error(),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    for n in 0..5 {
        let (status, _) = w.say(channel, &format!("message {n}")).await;
        assert_eq!(status, 200);
    }
    let (_, list) = admin_call(&w, &token, "GET", "/space/dock/hooks", None).await;
    assert_eq!(list[0]["failures"], json!(5), "{list}");
    assert!(!list.to_string().contains(SECRET), "{list}");
    let health = w.store.module_health().await.unwrap();
    let reason = health["echo"].disabled_reason.clone().unwrap();
    assert!(!reason.contains(SECRET), "{reason}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fail_closed_hook_that_keeps_failing_keeps_refusing_and_alerts() {
    let w = world("slimm-hooks-closed-breaker").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "strict",
        wasm: trapping(),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    let closed = HookChange {
        priority: None,
        fail_closed: Some(true),
    };
    let key = (HookKind::Interceptor, SEND, "reject");
    w.store
        .update_module_hook("strict", key, closed)
        .await
        .unwrap();
    for n in 0..8 {
        let (status, body) = w.say(channel, &format!("message {n}")).await;
        assert_eq!(status, 403, "send {n} must stay refused: {body}");
    }
    let module = w.store.installed_module("strict").await.unwrap().unwrap();
    assert!(module.enabled, "a fail-closed hook is not switched off");
    let alerts = w.store.list_admin_alerts(0).await.unwrap();
    assert!(
        alerts.iter().any(|a| a.kind == "module_breaker"
            && a.subject == "strict"
            && a.resolved_at.is_none()),
        "{alerts:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_servers_own_disable_is_audited_without_an_actor() {
    let w = world("slimm-hooks-system-audit").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "broken",
        wasm: trapping(),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    for n in 0..5 {
        w.say(channel, &format!("message {n}")).await;
    }
    let audit = w.store.admin_changes(None, 10).await.unwrap();
    let row = audit
        .iter()
        .find(|e| e.action == "module.auto_disable")
        .expect("the disable is audited");
    assert_eq!(row.target_id.as_deref(), Some("broken"));
    assert_eq!(row.actor_id, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn each_hook_of_a_module_reports_its_own_stats() {
    let w = world("slimm-hooks-own-stats").await;
    let channel = general(&w).await;
    let token = admin_token(&w).await;
    w.install_hook_module(HookModule {
        id: "two",
        wasm: answering(&json!({ "action": "allow" })),
        hooks: vec![
            interceptor(SEND, "reject", &["content"]),
            interceptor(EDIT, "reject", &["content"]),
        ],
    })
    .await;
    w.say(channel, "hello").await;
    let (_, list) = admin_call(&w, &token, "GET", "/space/dock/hooks", None).await;
    let runs_of = |hook: &str| {
        let row = list.as_array().unwrap().iter().find(|h| h["hook"] == hook);
        row.unwrap()["runs"].clone()
    };
    assert_eq!(runs_of(SEND), json!(1), "{list}");
    assert_eq!(runs_of(EDIT), json!(0), "{list}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_lowest_priority_is_refused_not_a_panic() {
    let w = world("slimm-hooks-min-priority").await;
    let token = admin_token(&w).await;
    w.install_hook_module(HookModule {
        id: "any",
        wasm: answering(&json!({ "action": "allow" })),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    let change =
        json!({ "kind": "interceptor", "hook": SEND, "phase": "reject", "priority": i64::MIN });
    let (status, _) = admin_call(
        &w,
        &token,
        "PUT",
        "/space/dock/modules/any/hooks",
        Some(change),
    )
    .await;
    assert_eq!(status, 400);
}
