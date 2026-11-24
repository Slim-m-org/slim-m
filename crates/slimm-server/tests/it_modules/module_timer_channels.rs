// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A one-shot timer posts into the channel it was armed in, as the module's principal, under the
//! permission check an interactive run in that channel gets.

use slimm_server::http::run_module_timers;
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, OverwriteBatchEntry, TimerSpec};

use crate::support;
use support::module_world::{Install, World, post_request, world};
use support::wasm_fixtures::host_call_loop_wasm;

fn far_future() -> i64 {
    i64::MAX / 2
}

async fn install_poster(w: &World, channel: &ChannelId) {
    let post = post_request(&channel.to_string(), "tick");
    w.install(Install {
        id: "pomo",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["schedule", "message.post"],
        approved_host: &["schedule", "message.post"],
    })
    .await;
    w.store.ensure_module_bot("pomo", "Pomo").await.unwrap();
}

async fn arm(w: &World, channel: Option<ChannelId>) {
    let timer = TimerSpec {
        command: "run",
        key: "k",
        input: "",
        channel_id: channel,
        run_at: 1,
    };
    assert!(w.store.set_module_timer("pomo", &timer, 32).await.unwrap());
}

async fn texts(w: &World, channel: ChannelId) -> Vec<String> {
    let page = w.store.list_messages(channel, None, 10).await.unwrap();
    page.into_iter().map(|m| m.content).collect()
}

async fn deny_send(w: &World, channel: ChannelId) {
    w.store
        .set_channel_overwrites_batch(
            channel,
            &[OverwriteBatchEntry {
                target_type: "role",
                target_id: w.everyone.0,
                allow: Permissions::NONE,
                deny: Permissions::SEND_MESSAGES,
            }],
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn a_timer_armed_in_a_channel_posts_there_not_in_the_schedule_channel() {
    let w = world("slimm-timer-chan-a").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    let schedule = w.store.create_channel("schedule", "text").await.unwrap();
    install_poster(&w, &a.id).await;
    w.store
        .set_module_schedule_channel("pomo", Some(schedule.id))
        .await
        .unwrap();
    arm(&w, Some(a.id)).await;

    assert_eq!(run_module_timers(&w.state, far_future()).await.unwrap(), 1);

    assert_eq!(texts(&w, a.id).await, vec!["tick"]);
    assert!(texts(&w, schedule.id).await.is_empty());
}

#[tokio::test]
async fn a_principal_that_may_not_send_in_the_channel_is_refused_and_posts_nowhere() {
    let w = world("slimm-timer-chan-denied").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    let other = w.store.create_channel("other", "text").await.unwrap();
    install_poster(&w, &a.id).await;
    w.store
        .set_module_schedule_channel("pomo", Some(other.id))
        .await
        .unwrap();
    deny_send(&w, a.id).await;
    arm(&w, Some(a.id)).await;

    assert_eq!(run_module_timers(&w.state, far_future()).await.unwrap(), 1);

    assert!(texts(&w, a.id).await.is_empty());
    assert!(texts(&w, other.id).await.is_empty());
}

#[tokio::test]
async fn a_module_cannot_aim_a_timer_run_at_another_channel() {
    let w = world("slimm-timer-chan-aim").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    let b = w.store.create_channel("b", "text").await.unwrap();
    install_poster(&w, &b.id).await;
    arm(&w, Some(a.id)).await;

    run_module_timers(&w.state, far_future()).await.unwrap();

    assert!(texts(&w, a.id).await.is_empty());
    assert!(texts(&w, b.id).await.is_empty());
}

#[tokio::test]
async fn a_timer_whose_channel_was_deleted_is_dropped_without_running() {
    let w = world("slimm-timer-chan-deleted").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    let schedule = w.store.create_channel("schedule", "text").await.unwrap();
    install_poster(&w, &a.id).await;
    w.store
        .set_module_schedule_channel("pomo", Some(schedule.id))
        .await
        .unwrap();
    arm(&w, Some(a.id)).await;
    w.store.delete_channel(a.id).await.unwrap();

    assert_eq!(run_module_timers(&w.state, far_future()).await.unwrap(), 0);

    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 0);
    assert!(texts(&w, schedule.id).await.is_empty());
}

#[tokio::test]
async fn a_timer_armed_in_a_thread_posts_in_that_thread() {
    let w = world("slimm-timer-chan-thread").await;
    let parent = w.store.create_channel("a", "text").await.unwrap();
    let root = MessageId::generate();
    w.store
        .send_message(NewMessage::plain(parent.id, w.user.id, root, "root"))
        .await
        .unwrap();
    let thread = w.store.open_thread(parent.id, root).await.unwrap().channel;
    install_poster(&w, &thread.id).await;
    arm(&w, Some(thread.id)).await;

    run_module_timers(&w.state, far_future()).await.unwrap();

    assert_eq!(texts(&w, thread.id).await, vec!["tick"]);
}

#[tokio::test]
async fn a_timer_armed_in_a_dm_posts_nothing_because_the_principal_is_no_participant() {
    let w = world("slimm-timer-chan-dm").await;
    let friend = w.store.create_user("bob", "Bob").await.unwrap();
    let dm = w.store.open_dm(w.user.id, friend.id).await.unwrap();
    install_poster(&w, &dm.id).await;
    arm(&w, Some(dm.id)).await;

    assert_eq!(run_module_timers(&w.state, far_future()).await.unwrap(), 1);

    assert!(texts(&w, dm.id).await.is_empty());
}

const ASKS: &[u8] =
    br#"{"ok":true,"output":"ok","run_after":{"command":"run","after_ms":1,"key":"c1"}}"#;

/// Lets `nia` run a `pomo` that answers with a timer, the way a reminder command does.
async fn install_asker(w: &World) {
    w.install(Install {
        id: "pomo",
        wasm: support::wasm_fixtures::canned_raw_wasm(ASKS),
        declared: &["schedule"],
        approved_host: &["schedule"],
    })
    .await;
    w.store.ensure_module_bot("pomo", "Pomo").await.unwrap();
}

async fn armed_channels(w: &World) -> Vec<Option<ChannelId>> {
    let due = w.store.due_module_timers(far_future(), 16).await.unwrap();
    due.into_iter().map(|t| t.channel_id).collect()
}

async fn overwrite_everyone(w: &World, channel: ChannelId, deny: Permissions) {
    let entry = OverwriteBatchEntry {
        target_type: "role",
        target_id: w.everyone.0,
        allow: Permissions::NONE,
        deny,
    };
    w.store
        .set_channel_overwrites_batch(channel, &[entry])
        .await
        .unwrap();
}

#[tokio::test]
async fn a_run_from_a_channel_the_invoker_may_post_in_arms_its_timer_there() {
    let w = world("slimm-timer-chan-invoker-ok").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    install_asker(&w).await;

    let answer = w.run_in("pomo", Some(a.id)).await;

    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(armed_channels(&w).await, vec![Some(a.id)]);
}

#[tokio::test]
async fn a_run_from_a_channel_the_invoker_cannot_see_is_refused_and_arms_nothing() {
    let w = world("slimm-timer-chan-invoker-hidden").await;
    let staff = w.store.create_channel("staff", "text").await.unwrap();
    overwrite_everyone(&w, staff.id, Permissions::VIEW_CHANNEL).await;
    install_asker(&w).await;

    let answer = w.run_in("pomo", Some(staff.id)).await;

    assert_ne!(answer["ok"], true, "{answer}");
    assert_eq!(w.store.pending_module_timers("pomo").await.unwrap(), 0);
}

#[tokio::test]
async fn a_timer_armed_where_the_invoker_may_not_post_keeps_no_channel_and_posts_nowhere() {
    let w = world("slimm-timer-chan-invoker-readonly").await;
    let news = w.store.create_channel("news", "text").await.unwrap();
    overwrite_everyone(&w, news.id, Permissions::SEND_MESSAGES).await;
    install_asker(&w).await;

    let answer = w.run_in("pomo", Some(news.id)).await;

    assert_eq!(
        answer["ok"], true,
        "a read-only channel still runs the command: {answer}"
    );
    assert_eq!(armed_channels(&w).await, vec![None]);
    install_poster(&w, &news.id).await;
    let bot = w.store.ensure_module_bot("pomo", "Pomo").await.unwrap();
    w.store
        .set_member_overwrite(news.id, bot, Permissions::SEND_MESSAGES, Permissions::NONE)
        .await
        .unwrap();
    run_module_timers(&w.state, far_future()).await.unwrap();
    assert!(texts(&w, news.id).await.is_empty());
}

#[tokio::test]
async fn a_removed_principal_s_timer_posts_nothing() {
    let w = world("slimm-timer-chan-removed").await;
    let a = w.store.create_channel("a", "text").await.unwrap();
    install_poster(&w, &a.id).await;
    let bot = w.store.ensure_module_bot("pomo", "Pomo").await.unwrap();
    arm(&w, Some(a.id)).await;
    let admin = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, admin).await.unwrap();
    w.store
        .remove_from_space(bot, w.user.id, None)
        .await
        .unwrap();

    assert_eq!(run_module_timers(&w.state, far_future()).await.unwrap(), 0);

    assert!(texts(&w, a.id).await.is_empty());
}
