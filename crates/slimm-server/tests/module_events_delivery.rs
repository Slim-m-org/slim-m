// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Events are checked again when they are delivered, not only when they are
//! queued (decision 0091), and a module is never sent its own messages.

use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::http::spawn_module_events;
use slimm_server::hub::Event;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

mod support;
use support::module_events_world::EventModule;
use support::module_world::{World, world};
use support::wait::wait_for;
use support::wasm_fixtures::{busy_ok_wasm, event_recorder_wasm};

/// Loop turns for a run that holds a worker for about a second.
const SPIN: u32 = 10_000_000;
/// Long enough for the consumer to queue what was just sent.
const QUEUED: Duration = Duration::from_millis(100);

async fn call(w: &World, token: &str, method: &str, uri: &str, body: Option<Value>) {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let body = match body {
        Some(body) => {
            builder = builder.header("content-type", "application/json");
            Body::from(body.to_string())
        }
        None => Body::empty(),
    };
    w.router
        .clone()
        .oneshot(builder.body(body).unwrap())
        .await
        .unwrap();
}

async fn send_as(w: &World, token: &str, channel: ChannelId, content: &str) -> MessageId {
    let id = MessageId::generate();
    let body = json!({ "id": id.to_string(), "content": content });
    call(
        w,
        token,
        "POST",
        &format!("/channels/{channel}/messages"),
        Some(body),
    )
    .await;
    id
}

async fn hide_from_everyone(w: &World, channel: ChannelId) {
    w.store
        .set_role_overwrite(
            channel,
            w.everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
}

/// A module whose first event keeps its worker busy while the next one waits.
async fn busy_module(w: &World) {
    w.install_event_module(EventModule {
        id: "busy",
        wasm: busy_ok_wasm(SPIN),
        subscribes: &["member.joined", "message.created", "message.deleted"],
        approved: &["events"],
    })
    .await;
}

async fn occupy_the_workers(w: &World) -> Instant {
    let started = Instant::now();
    w.hub.publish(Event::MemberJoined(UserId::generate()));
    tokio::time::sleep(QUEUED).await;
    started
}

/// Waits for `expected` runs, then for as long as another would take, and checks no more came.
async fn runs_once_settled(w: &World, module: &str, expected: i64, started: Instant) {
    wait_for("the busy runs to finish", || async {
        (w.event_runs(module).await >= expected).then_some(())
    })
    .await;
    let one_run = started.elapsed() / u32::try_from(expected).unwrap();
    tokio::time::sleep(one_run * 2).await;
    assert_eq!(w.event_runs(module).await, expected);
}

#[tokio::test]
async fn a_queued_event_for_a_channel_made_private_since_is_dropped() {
    let w = world("slimm-modevents-late-private").await;
    let _consumer = spawn_module_events(w.state.clone());
    busy_module(&w).await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    let started = occupy_the_workers(&w).await;
    send_as(&w, &w.token, channel, "now you see it").await;
    tokio::time::sleep(QUEUED).await;
    hide_from_everyone(&w, channel).await;
    runs_once_settled(&w, "busy", 1, started).await;
}

#[tokio::test]
async fn a_queued_message_created_for_a_message_deleted_since_is_dropped_but_its_deletion_is_not() {
    let w = world("slimm-modevents-late-delete").await;
    let _consumer = spawn_module_events(w.state.clone());
    busy_module(&w).await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    let started = occupy_the_workers(&w).await;
    let message = send_as(&w, &w.token, channel, "oops").await;
    tokio::time::sleep(QUEUED).await;
    call(
        &w,
        &w.token,
        "DELETE",
        &format!("/channels/{channel}/messages/{message}"),
        None,
    )
    .await;
    // The join, then the deletion; the created event for a gone message is skipped.
    runs_once_settled(&w, "busy", 2, started).await;
}

#[tokio::test]
async fn a_module_is_not_sent_the_messages_its_own_principal_wrote() {
    let w = world("slimm-modevents-own").await;
    let _consumer = spawn_module_events(w.state.clone());
    let bot = w
        .install_event_module(EventModule {
            id: "echo",
            wasm: event_recorder_wasm(),
            subscribes: &["message.created"],
            approved: &["events", "kv.store"],
        })
        .await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    let bot_token = w
        .store
        .open_session(bot, "module")
        .await
        .unwrap()
        .access_token;

    send_as(&w, &bot_token, channel, "my own words").await;
    let theirs = send_as(&w, &w.token, channel, "someone else").await;
    wait_for("the other message", || async {
        (w.event_runs("echo").await >= 1).then_some(())
    })
    .await;
    tokio::time::sleep(QUEUED).await;
    let seen = w.recorded_events("echo").await;
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_eq!(seen[0]["id"], json!(format!("message:{theirs}")));
}
