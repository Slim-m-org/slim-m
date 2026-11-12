// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The interceptor chain and the deny-only permission hook (decision 0100)
//! through every path that stores a member's text.

use serde_json::{Value, json};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{HookChange, HookKind};

use crate::support;
use support::module_hooks_world::{
    HookModule, answering, interceptor, permission_hook, rewrites_to_its_input, trapping,
};
use support::module_world::{Install, World, post_request, world};
use support::wasm_fixtures::{fuel_burner_wasm, host_call_loop_wasm};

const SEND: &str = "message.pre_send";
const EDIT: &str = "message.pre_edit";

async fn general(w: &World) -> ChannelId {
    w.store.create_channel("general", "text").await.unwrap().id
}

async fn texts(w: &World, channel: ChannelId) -> Vec<String> {
    w.list_messages_json(channel)
        .await
        .iter()
        .map(|m| m["content"].as_str().unwrap().to_owned())
        .collect()
}

async fn install_reject(w: &World, id: &str, hook: &str) {
    let reply = json!({ "action": "reject", "reason": "no links here" });
    w.install_hook_module(HookModule {
        id,
        wasm: answering(&reply),
        hooks: vec![interceptor(hook, "reject", &["content"])],
    })
    .await;
}

async fn install_rewrite(w: &World, id: &str, to: &str) {
    w.install_hook_module(HookModule {
        id,
        wasm: answering(&json!({ "content": to })),
        hooks: vec![interceptor(SEND, "rewrite", &["content"])],
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn with_no_hook_installed_a_send_runs_no_module() {
    let w = world("slimm-hooks-none").await;
    let channel = general(&w).await;
    let (status, body) = w.say(channel, "hello").await;
    assert_eq!(status, 200, "{body}");
    assert!(w.state.dock.hooks().is_idle(&w.store).await);
    assert_eq!(texts(&w, channel).await, ["hello"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reject_stops_a_send_and_shows_the_sender_the_reason() {
    let w = world("slimm-hooks-reject").await;
    let channel = general(&w).await;
    install_reject(&w, "linkfilter", SEND).await;
    let (status, body) = w.say(channel, "see http://spam").await;
    assert_eq!(status, 403, "{body}");
    let error = body["error"].as_str().unwrap();
    assert!(
        error.contains("linkfilter") && error.contains("no links here"),
        "{error}"
    );
    assert!(texts(&w, channel).await.is_empty(), "nothing was stored");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reject_on_edit_leaves_the_message_as_it_was() {
    let w = world("slimm-hooks-edit").await;
    let channel = general(&w).await;
    let (_, sent) = w.say(channel, "fine").await;
    install_reject(&w, "linkfilter", EDIT).await;
    let id = sent["id"].as_str().unwrap();
    let (status, body) = w.edit(channel, id, "now http://spam").await;
    assert_eq!(status, 403, "{body}");
    assert_eq!(texts(&w, channel).await, ["fine"]);
    let (sends, _) = w.say(channel, "http://still fine to send").await;
    assert_eq!(sends, 200, "an edit hook does not stand in front of a send");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rewrite_changes_what_is_stored_on_send_and_on_edit() {
    let w = world("slimm-hooks-rewrite").await;
    let channel = general(&w).await;
    install_rewrite(&w, "censor", "[removed]").await;
    let (status, body) = w.say(channel, "rude words").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["content"], json!("[removed]"));
    w.install_hook_module(HookModule {
        id: "editcensor",
        wasm: answering(&json!({ "content": "[edited out]" })),
        hooks: vec![interceptor(EDIT, "rewrite", &["content"])],
    })
    .await;
    let (status, edited) = w
        .edit(channel, body["id"].as_str().unwrap(), "more rude words")
        .await;
    assert_eq!(status, 200, "{edited}");
    assert_eq!(texts(&w, channel).await, ["[edited out]"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_annotation_is_stored_for_the_module_that_made_it() {
    let w = world("slimm-hooks-annotate").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "tagger",
        wasm: answering(&json!({ "annotations": { "topic": "greeting" } })),
        hooks: vec![interceptor(SEND, "annotate", &["content"])],
    })
    .await;
    let (_, body) = w.say(channel, "hi").await;
    let id = body["id"].as_str().unwrap().parse().unwrap();
    let stored = w
        .store
        .message_annotations(slimm_server::ids::MessageId(id), "tagger")
        .await
        .unwrap();
    let stored: Value = serde_json::from_str(&stored.unwrap()).unwrap();
    assert_eq!(stored, json!({ "topic": "greeting" }));
}

#[tokio::test(flavor = "multi_thread")]
async fn phases_run_reject_first_and_a_reject_stops_the_rewrites_after_it() {
    let w = world("slimm-hooks-phases").await;
    let channel = general(&w).await;
    install_rewrite(&w, "censor", "[removed]").await;
    install_reject(&w, "linkfilter", SEND).await;
    let (status, _) = w.say(channel, "http://x").await;
    assert_eq!(status, 403);
    assert_eq!(
        w.runs_of("censor", "@intercept").await,
        0,
        "the rewrite never ran"
    );
    assert_eq!(w.runs_of("linkfilter", "@intercept").await, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn within_a_phase_priority_orders_modules_and_the_admin_can_change_it() {
    let w = world("slimm-hooks-order").await;
    let channel = general(&w).await;
    install_rewrite(&w, "first", "one").await;
    install_rewrite(&w, "second", "two").await;
    let (_, body) = w.say(channel, "x").await;
    assert_eq!(
        body["content"],
        json!("two"),
        "the later install runs last and wins"
    );
    let key = (HookKind::Interceptor, SEND, "rewrite");
    let late = HookChange {
        priority: Some(500),
        fail_closed: None,
    };
    assert!(
        w.store
            .update_module_hook("first", key, late)
            .await
            .unwrap()
    );
    let (_, body) = w.say(channel, "x").await;
    assert_eq!(
        body["content"],
        json!("one"),
        "raising a priority moves it to the end"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rewrite_passes_down_the_chain() {
    let w = world("slimm-hooks-pass").await;
    let channel = general(&w).await;
    install_rewrite(&w, "censor", "[censored]").await;
    w.install_hook_module(HookModule {
        id: "witness",
        wasm: rewrites_to_its_input(),
        hooks: vec![interceptor(SEND, "rewrite", &["content"])],
    })
    .await;
    let (status, body) = w.say(channel, "the original").await;
    assert_eq!(status, 200, "{body}");
    let stored = body["content"].as_str().unwrap();
    assert!(
        stored.contains("[censored]"),
        "the later module was sent the rewrite: {stored}"
    );
    assert!(!stored.contains("the original"), "{stored}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_reject_phase_sees_the_senders_text_before_any_rewrite() {
    let w = world("slimm-hooks-reject-first").await;
    let channel = general(&w).await;
    install_rewrite(&w, "censor", "[censored]").await;
    w.install_hook_module(HookModule {
        id: "witness",
        wasm: answering(&json!({ "action": "allow" })),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    let (status, body) = w.say(channel, "the original").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["content"], json!("[censored]"));
    assert_eq!(w.runs_of("witness", "@intercept").await, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_trapping_module_fails_open_and_trips_the_breaker() {
    let w = world("slimm-hooks-trap").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "broken",
        wasm: trapping(),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    for n in 0..5 {
        let (status, body) = w.say(channel, &format!("message {n}")).await;
        assert_eq!(status, 200, "fail open: {body}");
    }
    assert_eq!(texts(&w, channel).await.len(), 5);
    let module = w.store.installed_module("broken").await.unwrap().unwrap();
    assert!(!module.enabled, "five failures in a row turn it off");
    let health = w.store.module_health().await.unwrap();
    assert!(
        health["broken"]
            .disabled_reason
            .as_deref()
            .unwrap()
            .contains("failed")
    );
    assert_eq!(w.runs_of("broken", "@intercept").await, 5);
    let (status, _) = w.say(channel, "after").await;
    assert_eq!(status, 200);
    assert_eq!(
        w.runs_of("broken", "@intercept").await,
        5,
        "no longer asked"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fail_closed_hook_refuses_when_it_cannot_check() {
    let w = world("slimm-hooks-closed").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "broken",
        wasm: trapping(),
        hooks: vec![interceptor(SEND, "reject", &["content"])],
    })
    .await;
    let key = (HookKind::Interceptor, SEND, "reject");
    let closed = HookChange {
        priority: None,
        fail_closed: Some(true),
    };
    w.store
        .update_module_hook("broken", key, closed)
        .await
        .unwrap();
    let (status, body) = w.say(channel, "hello").await;
    assert_eq!(status, 403, "{body}");
    assert!(body["error"].as_str().unwrap().contains("could not check"));
    assert!(texts(&w, channel).await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn three_slow_modules_cannot_hold_a_send_past_the_chain_cap() {
    let w = world("slimm-hooks-cap").await;
    let channel = general(&w).await;
    for id in ["slow-a", "slow-b", "slow-c"] {
        w.install_hook_module(HookModule {
            id,
            wasm: fuel_burner_wasm(),
            hooks: vec![interceptor(SEND, "reject", &["content"])],
        })
        .await;
    }
    let started = std::time::Instant::now();
    let (status, body) = w.say(channel, "hello").await;
    let took = started.elapsed();
    assert_eq!(status, 200, "fail open: {body}");
    assert!(
        took < std::time::Duration::from_millis(900),
        "took {took:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn webhooks_and_module_posts_go_through_the_chain_too() {
    let w = world("slimm-hooks-paths").await;
    let channel = general(&w).await;
    install_reject(&w, "linkfilter", SEND).await;
    let minted = w
        .store
        .create_webhook(channel, "alerts", w.user.id)
        .await
        .unwrap();
    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let (status, _) = w
        .call_json("POST", &path, json!({ "content": "http://x" }))
        .await;
    assert_eq!(status, 403, "a webhook is stopped by the same chain");
    let post = post_request(&channel.to_string(), "http://from-a-module");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let _ = w.run_in("announcer", Some(channel)).await;
    assert!(
        texts(&w, channel).await.is_empty(),
        "the module's post was refused"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_permission_hook_can_deny_a_send() {
    let w = world("slimm-hooks-deny").await;
    let quiet = general(&w).await;
    w.install_hook_module(HookModule {
        id: "gate",
        wasm: answering(&json!({ "allow": false, "reason": "new members wait" })),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
    let (status, body) = w.say(quiet, "hello").await;
    assert_eq!(status, 403, "{body}");
    assert!(body["error"].as_str().unwrap().contains("new members wait"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_permission_hook_can_never_grant_what_the_member_lacks() {
    let w = world("slimm-hooks-nogrant").await;
    let channel = general(&w).await;
    w.store
        .set_role_overwrite(
            channel,
            w.everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    w.install_hook_module(HookModule {
        id: "generous",
        wasm: answering(&json!({ "allow": true })),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
    let (status, _) = w.say(channel, "hello").await;
    assert_eq!(
        status, 403,
        "the core check refused and the hook has no say"
    );
    assert_eq!(
        w.runs_of("generous", "@allow").await,
        0,
        "it was never even asked"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_trapping_permission_hook_fails_open() {
    let w = world("slimm-hooks-permission-trap").await;
    let channel = general(&w).await;
    w.install_hook_module(HookModule {
        id: "broken",
        wasm: trapping(),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
    for _ in 0..5 {
        let (status, _) = w.say(channel, "hello").await;
        assert_eq!(status, 200);
    }
    assert!(
        !w.store
            .installed_module("broken")
            .await
            .unwrap()
            .unwrap()
            .enabled
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn permission_hooks_also_stand_in_front_of_reactions_uploads_and_voice() {
    let w = world("slimm-hooks-actions").await;
    let channel = general(&w).await;
    let talk = w.store.create_channel("talk", "voice").await.unwrap().id;
    let extras = Permissions::ADD_REACTIONS
        .union(Permissions::ATTACH_FILES)
        .union(Permissions::CONNECT);
    let role = w.store.create_role("extras", extras, false).await.unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();
    let (_, sent) = w.say(channel, "react to me").await;
    let message = sent["id"].as_str().unwrap().to_owned();
    let thumbs_up = "%F0%9F%91%8D";

    let (status, body) = w
        .call_json(
            "PUT",
            &format!("/messages/{message}/reactions/{thumbs_up}"),
            json!({}),
        )
        .await;
    assert_ne!(
        status, 403,
        "without a hook the reaction goes through: {body}"
    );

    w.install_hook_module(HookModule {
        id: "gate",
        wasm: answering(&json!({ "allow": false, "reason": "not today" })),
        hooks: ["reaction.add", "attachment.upload", "voice.join"]
            .map(permission_hook)
            .to_vec(),
    })
    .await;

    let react = format!("/messages/{message}/reactions/{thumbs_up}");
    let upload = format!("/attachments?channel_id={channel}");
    let voice = format!("/channels/{talk}/voice/token");
    for (method, uri) in [("PUT", react), ("POST", upload), ("POST", voice)] {
        let (status, body) = w.call_json(method, &uri, json!({})).await;
        assert_eq!(status, 403, "{uri}: {body}");
        assert!(
            body["error"].as_str().unwrap().contains("not today"),
            "{uri}: {body}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_admin_routes_list_hooks_in_order_and_change_one() {
    let w = world("slimm-hooks-admin").await;
    let admin = w.store.create_user("boss", "Boss").await.unwrap();
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    let token = w
        .store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;
    install_rewrite(&w, "first", "one").await;
    install_rewrite(&w, "second", "two").await;
    let call = |method: &'static str, uri: &'static str, body: Option<Value>| {
        let request = support::app::request(method, uri, Some(&token), body);
        let router = w.router.clone();
        async move {
            let response = tower::ServiceExt::oneshot(router, request).await.unwrap();
            let status = response.status().as_u16();
            (status, support::app::json_body_or_null(response).await)
        }
    };
    let (status, list) = call("GET", "/space/dock/hooks", None).await;
    assert_eq!(status, 200, "{list}");
    let ids: Vec<&str> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["module_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["first", "second"]);
    assert_eq!(list[0]["live"], json!(true));

    let change = json!({ "kind": "interceptor", "hook": SEND, "phase": "rewrite", "priority": 900, "fail_closed": true });
    let (status, _) = call("PUT", "/space/dock/modules/first/hooks", Some(change)).await;
    assert_eq!(status, 204);
    let (_, list) = call("GET", "/space/dock/hooks", None).await;
    assert_eq!(list[1]["module_id"], json!("first"));
    assert_eq!(list[1]["fail_closed"], json!(true));
    let missing = json!({ "kind": "interceptor", "hook": SEND, "phase": "reject" });
    let (status, _) = call("PUT", "/space/dock/modules/first/hooks", Some(missing)).await;
    assert_eq!(status, 404);

    let (status, _) = w.call_json("GET", "/space/dock/hooks", json!({})).await;
    assert_eq!(status, 403, "a member is not an administrator");
}
