// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pushed events (decision 0091): what a subscribed module is sent when
//! something happens, and what it is never sent.

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
use support::wasm_fixtures::event_recorder_wasm;

const THUMBS_UP: &str = "\u{1F44D}";
const ALL_EVENTS: [&str; 6] = [
    "message.created",
    "message.deleted",
    "reaction.changed",
    "member.joined",
    "member.left",
    "voice.session.closed",
];

async fn listener(w: &World, id: &str, subscribes: &[&str]) -> UserId {
    w.install_event_module(EventModule {
        id,
        wasm: event_recorder_wasm(),
        subscribes,
        approved: &["events", "kv.store"],
    })
    .await
}

async fn request(w: &World, method: &str, uri: &str, body: Option<Value>) {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {}", w.token));
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

async fn send_message(w: &World, channel: ChannelId, content: &str) -> MessageId {
    let id = MessageId::generate();
    let body = json!({ "id": id.to_string(), "content": content });
    request(
        w,
        "POST",
        &format!("/channels/{channel}/messages"),
        Some(body),
    )
    .await;
    id
}

async fn recorded_of(w: &World, module: &str, kind: &str, count: usize) -> Vec<Value> {
    wait_for(&format!("{count} {kind} event(s)"), || async {
        let all = w.recorded_events(module).await;
        let of_kind: Vec<Value> = all.into_iter().filter(|e| e["event"] == kind).collect();
        (of_kind.len() >= count).then_some(of_kind)
    })
    .await
}

#[tokio::test]
async fn each_event_kind_reaches_a_subscribed_module_with_its_documented_fields() {
    let w = world("slimm-modevents-kinds").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w, "listener", &ALL_EVENTS).await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            general.id,
            w.everyone,
            Permissions::ADD_REACTIONS,
            Permissions::NONE,
        )
        .await
        .unwrap();

    let message = send_message(&w, general.id, "hello module").await;
    let created = &recorded_of(&w, "listener", "message.created", 1).await[0];
    assert_eq!(created["id"], json!(format!("message:{message}")));
    assert_eq!(
        created["data"],
        json!({
            "message_id": message.to_string(),
            "channel_id": general.id.to_string(),
            "author_id": w.user.id.to_string(),
            "content": "hello module",
            "created_at_ms": created["at_ms"],
            "is_bot": false,
        })
    );

    let react = format!("/messages/{message}/reactions/%F0%9F%91%8D");
    request(&w, "PUT", &react, None).await;
    let reaction = &recorded_of(&w, "listener", "reaction.changed", 1).await[0];
    assert_eq!(
        reaction["data"],
        json!({
            "message_id": message.to_string(),
            "channel_id": general.id.to_string(),
            "emoji": THUMBS_UP,
            "count": 1,
        })
    );

    request(
        &w,
        "DELETE",
        &format!("/channels/{}/messages/{message}", general.id),
        None,
    )
    .await;
    let deleted = &recorded_of(&w, "listener", "message.deleted", 1).await[0];
    assert_eq!(deleted["id"], json!(format!("message-deleted:{message}")));
    assert_eq!(
        deleted["data"],
        json!({ "message_id": message.to_string(), "channel_id": general.id.to_string() })
    );

    let newcomer = UserId::generate();
    w.hub.publish(Event::MemberJoined(newcomer));
    w.hub.publish(Event::MemberRemoved(newcomer));
    let joined = &recorded_of(&w, "listener", "member.joined", 1).await[0];
    let left = &recorded_of(&w, "listener", "member.left", 1).await[0];
    assert_eq!(joined["data"], json!({ "user_id": newcomer.to_string() }));
    assert_eq!(left["data"], json!({ "user_id": newcomer.to_string() }));
    assert!(
        joined["id"]
            .as_str()
            .unwrap()
            .starts_with(&format!("member-join:{newcomer}:"))
    );

    w.hub.publish(Event::VoiceSessionClosed {
        session_id: 42,
        user_id: newcomer,
        channel_id: general.id,
        joined_at_ms: 1_000,
        left_at_ms: 9_000,
        alone_ms: 2_500,
    });
    let voice = &recorded_of(&w, "listener", "voice.session.closed", 1).await[0];
    assert_eq!(voice["id"], json!("voice-session:42"));
    assert_eq!(voice["at_ms"], json!(9_000));
    assert_eq!(
        voice["data"],
        json!({
            "session_id": 42,
            "user_id": newcomer.to_string(),
            "channel_id": general.id.to_string(),
            "joined_at_ms": 1_000,
            "left_at_ms": 9_000,
            "alone_ms": 2_500,
        })
    );
}

#[tokio::test]
async fn a_module_without_the_approval_or_the_subscription_or_enabled_gets_nothing() {
    let w = world("slimm-modevents-gates").await;
    let _consumer = spawn_module_events(w.state.clone());
    let wasm = event_recorder_wasm;
    listener(&w, "control", &["message.created"]).await;
    w.install_event_module(EventModule {
        id: "unapproved",
        wasm: wasm(),
        subscribes: &["message.created"],
        approved: &["events", "kv.store"],
    })
    .await;
    // Declared, but the admin approved only the store.
    w.store
        .set_module_host_capabilities("unapproved", &["kv.store".to_owned()])
        .await
        .unwrap();
    listener(&w, "elsewhere", &["member.left"]).await;
    listener(&w, "switched-off", &["message.created"]).await;
    w.store
        .set_module_enabled("switched-off", false)
        .await
        .unwrap();
    let general = w.store.create_channel("general", "text").await.unwrap();

    send_message(&w, general.id, "anyone there").await;
    recorded_of(&w, "control", "message.created", 1).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    for silent in ["unapproved", "elsewhere", "switched-off"] {
        assert_eq!(w.event_runs(silent).await, 0, "{silent} was run");
        assert!(
            w.recorded_events(silent).await.is_empty(),
            "{silent} recorded"
        );
    }
}

#[tokio::test]
async fn a_channel_the_principal_cannot_view_and_a_direct_message_deliver_nothing() {
    let w = world("slimm-modevents-private").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w, "listener", &["message.created", "message.deleted"]).await;
    let secret = w.store.create_channel("secret", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            secret.id,
            w.everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let open = w.store.create_channel("open", "text").await.unwrap();
    let friend = w.store.create_user("pal", "Pal").await.unwrap();
    let dm = w.store.open_dm(w.user.id, friend.id).await.unwrap();

    w.hub.publish(Event::MessageDeleted {
        channel_id: secret.id,
        message_id: MessageId::generate(),
        op_seq: None,
    });
    send_message(&w, dm.id, "a private word").await;
    let visible = MessageId::generate();
    w.hub.publish(Event::MessageDeleted {
        channel_id: open.id,
        message_id: visible,
        op_seq: None,
    });

    let seen = recorded_of(&w, "listener", "message.deleted", 1).await;
    assert_eq!(seen[0]["data"]["message_id"], json!(visible.to_string()));
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(
        w.event_runs("listener").await,
        1,
        "only the visible channel's event ran"
    );
    assert_eq!(w.recorded_events("listener").await.len(), 1);
}

#[tokio::test]
async fn an_event_keeps_its_id_when_it_arrives_again() {
    let w = world("slimm-modevents-ids").await;
    let _consumer = spawn_module_events(w.state.clone());
    listener(&w, "listener", &["voice.session.closed"]).await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let closed = || Event::VoiceSessionClosed {
        session_id: 7,
        user_id: w.user.id,
        channel_id: general.id,
        joined_at_ms: 1,
        left_at_ms: 2,
        alone_ms: 0,
    };
    w.hub.publish(closed());
    w.hub.publish(closed());

    wait_for("two deliveries", || async {
        (w.event_runs("listener").await == 2).then_some(())
    })
    .await;
    let seen = w.recorded_events("listener").await;
    let ids: Vec<&Value> = seen.iter().map(|e| &e["id"]).collect();
    assert_eq!(ids, [&json!("voice-session:7"), &json!("voice-session:7")]);
}

#[tokio::test]
async fn a_consumer_that_falls_behind_counts_what_it_missed_and_keeps_delivering() {
    let w = world("slimm-modevents-lagged").await;
    let consumer = spawn_module_events(w.state.clone());
    listener(&w, "listener", &["member.left"]).await;

    // No await between publishes, so the consumer cannot drain while this runs.
    for _ in 0..1_600 {
        w.hub.publish(Event::MemberJoined(UserId::generate()));
    }
    wait_for("the lag to be counted", || async {
        (consumer.lagged.load(std::sync::atomic::Ordering::Relaxed) > 0).then_some(())
    })
    .await;

    let leaver = UserId::generate();
    w.hub.publish(Event::MemberRemoved(leaver));
    let left = &recorded_of(&w, "listener", "member.left", 1).await[0];
    assert_eq!(left["data"]["user_id"], json!(leaver.to_string()));
}
