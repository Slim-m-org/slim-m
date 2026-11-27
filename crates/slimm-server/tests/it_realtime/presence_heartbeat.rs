// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A client with no socket stays present by heartbeating over REST: it reads online with its
//! activity until the heartbeat lapses, fans out like a socket, and never outranks appear-offline.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::presence::Visibility;
use tower::ServiceExt;

use crate::support;
use support::app::request_authed as request;
use support::ws::{connect, serve, user_ticket, wait_for_frame};

async fn call(state: &AppState, req: Request<Body>) -> (StatusCode, Value) {
    let response = http::router(state.clone()).oneshot(req).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn reading(state: &AppState, viewer: &str, target: &str) -> Value {
    let (status, body) = call(
        state,
        request("GET", &format!("/presence?ids={target}"), viewer, None),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    body[0].clone()
}

async fn beat(state: &AppState, token: &str, body: Value) -> (StatusCode, Value) {
    call(
        state,
        request("PUT", "/presence/heartbeat", token, Some(body)),
    )
    .await
}

struct World {
    state: AppState,
    agent: (String, String),
    watcher: (String, String, String),
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-presence-heartbeat").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (agent_token, _t, agent_id) = user_ticket(&store, "agent").await;
    let (watcher_token, watcher_ticket, _w) = user_ticket(&store, "watcher").await;
    World {
        state,
        agent: (agent_token, agent_id.to_string()),
        watcher: (watcher_token, watcher_ticket, _w.to_string()),
        _guard: guard,
    }
}

#[tokio::test]
async fn a_heartbeat_reads_online_with_its_activity_until_it_ends() {
    let w = world().await;
    let (token, id) = &w.agent;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "offline"
    );

    let (status, body) = beat(
        &w.state,
        token,
        json!({"activity": {"type": "playing", "title": "Chess"}, "ttl_seconds": 120}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["ttl_seconds"], 120);

    let seen = reading(&w.state, &w.watcher.0, id).await;
    assert_eq!(seen["status"], "online");
    assert_eq!(seen["activity"]["title"], "Chess");

    let (status, _) = call(
        &w.state,
        request("DELETE", "/presence/heartbeat", token, None),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let seen = reading(&w.state, &w.watcher.0, id).await;
    assert_eq!(seen["status"], "offline");
    assert!(seen.get("activity").is_none());
}

#[tokio::test]
async fn a_heartbeat_lapses_when_its_ttl_does() {
    let w = world().await;
    let (token, id) = &w.agent;
    beat(&w.state, token, json!({"ttl_seconds": 1})).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "online"
    );
    tokio::time::sleep(Duration::from_millis(1400)).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "offline"
    );
}

#[tokio::test]
async fn refreshing_extends_the_same_heartbeat() {
    let w = world().await;
    let (token, id) = &w.agent;
    beat(&w.state, token, json!({"ttl_seconds": 1})).await;
    tokio::time::sleep(Duration::from_millis(600)).await;
    beat(&w.state, token, json!({"ttl_seconds": 2})).await;
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "online"
    );
    tokio::time::sleep(Duration::from_millis(1400)).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "offline"
    );
}

#[tokio::test]
async fn bad_heartbeats_are_refused() {
    let w = world().await;
    let token = &w.agent.0;
    for body in [
        json!({"ttl_seconds": 0}),
        json!({"ttl_seconds": 301}),
        json!({"status": "hidden"}),
        json!({"status": "busy"}),
        json!({"activity": {"type": "playing", "title": ""}}),
    ] {
        let (status, _) = beat(&w.state, token, body.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }
    let (status, _) = beat(&w.state, token, json!({"ttl_seconds": 300})).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn the_status_asked_for_shows_and_a_hidden_member_stays_offline() {
    let w = world().await;
    let (token, id) = &w.agent;
    beat(&w.state, token, json!({"status": "dnd"})).await;
    assert_eq!(reading(&w.state, &w.watcher.0, id).await["status"], "dnd");
    beat(&w.state, token, json!({"status": "away"})).await;
    assert_eq!(reading(&w.state, &w.watcher.0, id).await["status"], "away");

    let agent = slimm_server::ids::UserId(id.parse().unwrap());
    w.state
        .store
        .set_presence_visibility(agent, Visibility::Hidden)
        .await
        .unwrap();
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "offline"
    );
}

#[tokio::test]
async fn a_durable_dnd_choice_outranks_a_heartbeat_saying_online() {
    let w = world().await;
    let (token, id) = &w.agent;
    let agent = slimm_server::ids::UserId(id.parse().unwrap());
    w.state
        .store
        .set_presence_visibility(agent, Visibility::Dnd)
        .await
        .unwrap();
    beat(&w.state, token, json!({"status": "online"})).await;
    assert_eq!(reading(&w.state, &w.watcher.0, id).await["status"], "dnd");
}

#[tokio::test]
async fn activity_put_applies_while_a_heartbeat_is_live_and_only_then() {
    let w = world().await;
    let (token, id) = &w.agent;
    let activity = json!({"type": "playing", "title": "Go"});
    let put = |t: &str| request("PUT", "/presence/activity", t, Some(activity.clone()));
    call(&w.state, put(token)).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["status"],
        "offline"
    );

    beat(&w.state, token, json!({"ttl_seconds": 60})).await;
    call(&w.state, put(token)).await;
    assert_eq!(
        reading(&w.state, &w.watcher.0, id).await["activity"]["title"],
        "Go"
    );
}

#[tokio::test]
async fn a_socket_and_a_heartbeat_together_stay_online_until_both_are_gone() {
    let (store, _guard) = support::new_store("slimm-presence-heartbeat-ws").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let addr = serve(state.clone()).await;
    let (token, ticket, id) = user_ticket(&store, "both").await;
    let (watcher, _t, _w) = user_ticket(&store, "viewer").await;
    let id = id.to_string();

    let socket = connect(addr, &ticket).await;
    beat(&state, &token, json!({"ttl_seconds": 1})).await;
    tokio::time::sleep(Duration::from_millis(1400)).await;
    assert_eq!(reading(&state, &watcher, &id).await["status"], "online");

    beat(&state, &token, json!({"ttl_seconds": 60})).await;
    drop(socket);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(reading(&state, &watcher, &id).await["status"], "online");
    call(
        &state,
        request("DELETE", "/presence/heartbeat", &token, None),
    )
    .await;
    assert_eq!(reading(&state, &watcher, &id).await["status"], "offline");
}

#[tokio::test]
async fn a_heartbeat_and_its_end_fan_out_like_a_socket() {
    let w = world().await;
    let (token, id) = &w.agent;
    let addr = serve(w.state.clone()).await;
    let mut watcher_ws = connect(addr, &w.watcher.1).await;
    let mut next = async |want: &str| {
        loop {
            let frame = wait_for_frame(&mut watcher_ws, "presence.changed", Duration::from_secs(2))
                .await
                .unwrap_or_else(|| panic!("no frame for {want}"));
            if frame["user_id"] == *id {
                return frame;
            }
        }
    };

    beat(&w.state, token, json!({"ttl_seconds": 1})).await;
    assert_eq!(next("online").await["status"], "online");
    let lapsed = next("lapse").await;
    assert_eq!(lapsed["status"], "offline");

    beat(&w.state, token, json!({"ttl_seconds": 60})).await;
    assert_eq!(next("again").await["status"], "online");
    call(
        &w.state,
        request("DELETE", "/presence/heartbeat", token, None),
    )
    .await;
    assert_eq!(next("ended").await["status"], "offline");
}

#[tokio::test]
async fn listing_presence_without_ids_is_refused() {
    let w = world().await;
    let token = &w.agent.0;
    for uri in ["/presence", "/presence?ids=", "/presence?ids=,%20,"] {
        let (status, body) = call(&w.state, request("GET", uri, token, None)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
        assert_eq!(body["error"], "ids is required");
    }
}

#[tokio::test]
async fn a_hidden_members_heartbeat_sends_no_frame() {
    let w = world().await;
    let (token, id) = &w.agent;
    let agent = slimm_server::ids::UserId(id.parse().unwrap());
    w.state
        .store
        .set_presence_visibility(agent, Visibility::Hidden)
        .await
        .unwrap();
    let addr = serve(w.state.clone()).await;
    let mut watcher_ws = connect(addr, &w.watcher.1).await;
    beat(&w.state, token, json!({"ttl_seconds": 1})).await;
    tokio::time::sleep(Duration::from_millis(1400)).await;
    while let Some(frame) = wait_for_frame(
        &mut watcher_ws,
        "presence.changed",
        Duration::from_millis(300),
    )
    .await
    {
        assert_ne!(frame["user_id"], *id, "a hidden member's heartbeat leaked");
    }
}
