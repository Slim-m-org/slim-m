// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's display name in a run request, and `{{mention:<caller id>}}` in a module's post.

use axum::body::Body;
use axum::http::Request;
use serde_json::json;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::OverwriteBatchEntry;

use crate::support;
use support::module_world::{Install, World, message_id_in, post_request, world};
use support::wasm_fixtures::{echo_request_wasm, host_call_loop_wasm};

async fn install_echo(w: &World, id: &str) {
    w.install(Install {
        id,
        wasm: echo_request_wasm(),
        declared: &[],
        approved_host: &[],
    })
    .await;
}

async fn allow_runs(w: &World, user: UserId, module: &str) {
    let role = w
        .store
        .create_role(&format!("bob-runs-{module}"), Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(user, role).await.unwrap();
    w.store
        .grant_module_permission(role, module, "run")
        .await
        .unwrap();
}

async fn run_as(w: &World, token: &str, module: &str, channel: Option<ChannelId>) -> String {
    let mut body = json!({ "input": "go" });
    if let Some(channel) = channel {
        body["channel_id"] = json!(channel.to_string());
    }
    let request = Request::builder()
        .method("POST")
        .uri(format!("/modules/{module}/commands/run"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let answer = w.send(request).await;
    answer["output"]
        .as_str()
        .or_else(|| answer["error"].as_str())
        .unwrap_or_else(|| panic!("no answer in {answer}"))
        .to_owned()
}

fn caller_id_in(echo: &str) -> String {
    let start = echo.find("'id':'").expect("a caller id") + "'id':'".len();
    echo[start..start + 64].to_owned()
}

async fn bob(w: &World) -> (UserId, String) {
    let bob = w.store.create_user("bob", "Bobby").await.unwrap();
    let token = w
        .store
        .open_session(bob.id, "pc")
        .await
        .unwrap()
        .access_token;
    (bob.id, token)
}

/// Bob's caller id for `module`, as the module is handed it.
async fn bobs_id(w: &World, module: &str) -> (UserId, String) {
    install_echo(w, module).await;
    let (bob, token) = bob(w).await;
    allow_runs(w, bob, module).await;
    let echo = run_as(w, &token, module, None).await;
    (bob, caller_id_in(&echo))
}

async fn post_as_module(w: &World, module: &str, channel: ChannelId, content: &str) -> String {
    let post = post_request(&channel.to_string(), content);
    w.install(Install {
        id: module,
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    w.answer_in(module, Some(channel)).await
}

#[tokio::test]
async fn the_request_carries_the_display_name_members_see() {
    let w = world("slimm-caller-name").await;
    install_echo(&w, "echo").await;

    let plain = run_as(&w, &w.token, "echo", None).await;
    assert!(plain.contains("'name':'Nia'"), "{plain}");

    w.store
        .set_nickname(w.user.id, "Captain", w.user.id)
        .await
        .unwrap();
    let nicked = run_as(&w, &w.token, "echo", None).await;
    assert!(nicked.contains("'name':'Captain'"), "{nicked}");
}

#[tokio::test]
async fn a_member_without_a_display_name_is_named_by_username() {
    let w = world("slimm-caller-name-username").await;
    install_echo(&w, "echo").await;
    let blank = w.store.create_user("quiet", "").await.unwrap();
    let token = w
        .store
        .open_session(blank.id, "pc")
        .await
        .unwrap()
        .access_token;
    allow_runs(&w, blank.id, "echo").await;

    let echo = run_as(&w, &token, "echo", None).await;

    assert!(echo.contains("'name':'quiet'"), "{echo}");
}

#[tokio::test]
async fn a_caller_token_becomes_a_real_mention() {
    let w = world("slimm-mention-token").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let (bob, id) = bobs_id(&w, "announcer").await;

    let answer = post_as_module(
        &w,
        "announcer",
        channel.id,
        &format!("hi {{{{mention:{id}}}}}!"),
    )
    .await;

    let message = message_id_in(&answer);
    let stored = w
        .store
        .message_including_deleted(message)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content, "hi @bob!");
    assert!(w.store.is_mentioned(message, bob).await.unwrap());
}

#[tokio::test]
async fn an_id_the_module_was_never_given_reads_as_a_member_and_mentions_nobody() {
    let w = world("slimm-mention-forged").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let (bob, _) = bobs_id(&w, "other").await;
    let forged = "a".repeat(64);
    let content = format!("{{{{mention:{forged}}}}} @everyone");

    let answer = post_as_module(&w, "announcer", channel.id, &content).await;

    let message = message_id_in(&answer);
    let stored = w
        .store
        .message_including_deleted(message)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content, "a member @everyone");
    assert!(!w.store.is_mentioned(message, bob).await.unwrap());
}

#[tokio::test]
async fn a_malformed_token_stays_literal() {
    let w = world("slimm-mention-malformed").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let content = "{{mention:abc}} {{mention:}}";

    let answer = post_as_module(&w, "announcer", channel.id, content).await;

    let stored = w
        .store
        .message_including_deleted(message_id_in(&answer))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content, content);
}

#[tokio::test]
async fn an_id_given_to_another_module_does_not_work_here() {
    let w = world("slimm-mention-other-module").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let (bob, id) = bobs_id(&w, "other").await;
    let content = format!("{{{{mention:{id}}}}}");

    let answer = post_as_module(&w, "announcer", channel.id, &content).await;

    let message = message_id_in(&answer);
    let stored = w
        .store
        .message_including_deleted(message)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content, "a member");
    assert!(!w.store.is_mentioned(message, bob).await.unwrap());
}

#[tokio::test]
async fn at_most_ten_tokens_in_a_message_are_expanded() {
    let w = world("slimm-mention-cap").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let (_, id) = bobs_id(&w, "announcer").await;
    let token = format!("{{{{mention:{id}}}}}");
    let content = [token.as_str(); 12].join(" ");

    let answer = post_as_module(&w, "announcer", channel.id, &content).await;

    let stored = w
        .store
        .message_including_deleted(message_id_in(&answer))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content.matches("@bob").count(), 10);
    assert_eq!(stored.content.matches("a member").count(), 2);
    assert!(!stored.content.contains("mention:"));
}

#[tokio::test]
async fn a_member_who_cannot_see_the_channel_is_not_mentioned_or_named() {
    let w = world("slimm-mention-hidden").await;
    let channel = w.store.create_channel("staff", "text").await.unwrap();
    let (bob, id) = bobs_id(&w, "announcer").await;
    w.store
        .set_channel_overwrites_batch(
            channel.id,
            &[
                OverwriteBatchEntry {
                    target_type: "role",
                    target_id: w.everyone.0,
                    allow: Permissions::NONE,
                    deny: Permissions::VIEW_CHANNEL,
                },
                OverwriteBatchEntry {
                    target_type: "member",
                    target_id: w.user.id.0,
                    allow: Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
                    deny: Permissions::NONE,
                },
            ],
        )
        .await
        .unwrap();
    let content = format!("{{{{mention:{id}}}}}");

    let answer = post_as_module(&w, "announcer", channel.id, &content).await;

    let message = message_id_in(&answer);
    let stored = w
        .store
        .message_including_deleted(message)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.content, "a member");
    assert!(!w.store.is_mentioned(message, bob).await.unwrap());
}

/// A caller whose username ends in `.`, so a token for them is written as their display name.
async fn dotted_caller(w: &World, module: &str, display_name: &str) -> (UserId, String) {
    install_echo(w, module).await;
    let eve = w.store.create_user("eve.", display_name).await.unwrap();
    let token = w
        .store
        .open_session(eve.id, "pc")
        .await
        .unwrap()
        .access_token;
    allow_runs(w, eve.id, module).await;
    let echo = run_as(w, &token, module, None).await;
    (eve.id, caller_id_in(&echo))
}

async fn module_principal_may_mention_everyone(w: &World, module: &str) {
    let bot = w
        .store
        .ensure_module_bot(module, "Scorekeeper")
        .await
        .unwrap();
    let role = w
        .store
        .create_role("module-pingers", Permissions::MENTION_EVERYONE, false)
        .await
        .unwrap();
    w.store.assign_role(bot, role).await.unwrap();
}

#[tokio::test]
async fn a_display_name_naming_other_people_does_not_mention_them() {
    let w = world("slimm-mention-injection").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let alice = w.store.create_user("alice", "Alice").await.unwrap().id;
    let carol = w.store.create_user("carol", "Carol").await.unwrap().id;
    let mods = w
        .store
        .create_role("Mods", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(carol, mods).await.unwrap();
    let (eve, id) = dotted_caller(&w, "announcer", "@alice @everyone @here @[Mods]").await;
    module_principal_may_mention_everyone(&w, "announcer").await;

    let answer = post_as_module(
        &w,
        "announcer",
        channel.id,
        &format!("hi {{{{mention:{id}}}}}"),
    )
    .await;

    let message = message_id_in(&answer);
    let stored = w
        .store
        .message_including_deleted(message)
        .await
        .unwrap()
        .unwrap();
    for victim in [alice, carol] {
        assert!(
            !w.store.is_mentioned(message, victim).await.unwrap(),
            "{}",
            stored.content
        );
    }
    assert!(w.store.is_mentioned(message, eve).await.unwrap());
}

#[tokio::test]
async fn a_nickname_naming_other_people_does_not_mention_them() {
    let w = world("slimm-mention-injection-nick").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let alice = w.store.create_user("alice", "Alice").await.unwrap().id;
    let (eve, id) = dotted_caller(&w, "announcer", "Eve").await;
    w.store.set_nickname(eve, "@alice", eve).await.unwrap();

    let answer = post_as_module(
        &w,
        "announcer",
        channel.id,
        &format!("hi {{{{mention:{id}}}}}"),
    )
    .await;

    let message = message_id_in(&answer);
    assert!(!w.store.is_mentioned(message, alice).await.unwrap());
}

#[tokio::test]
async fn a_username_token_still_pings_next_to_a_hostile_name() {
    let w = world("slimm-mention-injection-control").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let (bob, bob_id) = bobs_id(&w, "announcer").await;
    let (_, eve_id) = dotted_caller(&w, "announcer", "@bob").await;
    let content = format!("{{{{mention:{eve_id}}}}} {{{{mention:{bob_id}}}}}");

    let answer = post_as_module(&w, "announcer", channel.id, &content).await;

    assert!(
        w.store
            .is_mentioned(message_id_in(&answer), bob)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn a_timer_post_cannot_borrow_a_names_everyone_even_from_a_principal_that_may() {
    use slimm_server::http::run_module_timers;
    use slimm_server::store::TimerSpec;

    let w = world("slimm-mention-injection-timer").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let alice = w.store.create_user("alice", "Alice").await.unwrap().id;
    let (_, id) = dotted_caller(&w, "pomo", "@everyone").await;
    module_principal_may_mention_everyone(&w, "pomo").await;
    let post = post_request(&channel.id.to_string(), &format!("{{{{mention:{id}}}}}"));
    w.install(Install {
        id: "pomo",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["schedule", "message.post"],
        approved_host: &["schedule", "message.post"],
    })
    .await;
    let timer = TimerSpec {
        command: "run",
        key: "k",
        input: "",
        channel_id: Some(channel.id),
        run_at: 1,
    };
    assert!(w.store.set_module_timer("pomo", &timer, 32).await.unwrap());

    assert_eq!(run_module_timers(&w.state, i64::MAX / 2).await.unwrap(), 1);

    let posted = w.store.list_messages(channel.id, None, 10).await.unwrap();
    let message = posted.first().expect("the timer posted").id;
    assert!(!w.store.is_mentioned(message, alice).await.unwrap());
}
