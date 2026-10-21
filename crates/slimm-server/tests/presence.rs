// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end presence tests: the appear-offline leak test (through both the
//! REST batch lookup and the WebSocket broadcast), and that presence flips to
//! offline when the last live socket closes rather than only when a client
//! says so.

use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::SinkExt;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::presence;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::ws::{Client, connect, read_frame, serve, user_ticket};

/// Reads frames until one is a `presence.changed` for `user_id`, ignoring any
/// other event kind. Bounded so a missing event fails the test instead of
/// hanging it.
async fn next_presence_for(ws: &mut Client, user_id: &str) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == "presence.changed" && frame["user_id"] == user_id {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no presence.changed for {user_id} arrived in time"))
}

/// A `tokio::time::interval` fires its first tick immediately, and on the
/// test's current-thread runtime that tick can land after the test has already
/// wound the clock back, announcing the idle transition without the poll ever
/// having repeated. Waiting out that first tick while the user is still active
/// means the transition below can only be seen by a later tick - which is the
/// periodic poll these tests exist to cover, and why a long interval fails
/// them instead of passing by accident.
async fn let_the_first_tick_pass() {
    tokio::time::sleep(Duration::from_millis(60)).await;
}

fn get_request(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

fn patch_request(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("PATCH")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn presence_status(state: &AppState, token: &str, target_id: &str) -> String {
    let uri = format!("/presence?ids={target_id}");
    let response = http::router(state.clone())
        .oneshot(get_request(&uri, token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let entries: Vec<Value> = serde_json::from_slice(&body).unwrap();
    entries[0]["status"].as_str().unwrap().to_owned()
}

/// A hidden user reads as offline to another user, but their own client still
/// sees their true (connected, online) state, through both the REST batch
/// lookup and the WebSocket broadcast. This is the appear-offline leak test:
/// the same underlying event and the same REST query, answered differently
/// only because the viewer differs.
#[tokio::test]
async fn hidden_user_reads_offline_to_others_but_true_to_self() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    let addr = serve(state.clone()).await;

    // Bob connects first so he is already subscribed when alice's connect
    // (and later her visibility change) publishes.
    let mut bob_ws = connect(addr, &bob_ticket).await;
    // Bob's own connect published his own presence; drain it before looking
    // for alice's.
    let bob_self = next_presence_for(&mut bob_ws, &_bob_id.to_string()).await;
    assert_eq!(bob_self["status"], "online");

    let mut alice_ws = connect(addr, &alice_ticket).await;

    // Alice's own connection sees her true state immediately on connect.
    let alice_self = next_presence_for(&mut alice_ws, &alice_id_str).await;
    assert_eq!(alice_self["status"], "online");
    // Bob, a different viewer, sees the same default-visibility online state.
    let bob_view = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(bob_view["status"], "online");

    // Alice sets appear-offline over REST.
    let response = http::router(state.clone())
        .oneshot(patch_request(
            "/presence",
            &alice_access,
            json!({ "visibility": "hidden" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // Alice's own live connection still reports her true state: connected,
    // so online, never forced offline for herself.
    let alice_self_after = next_presence_for(&mut alice_ws, &alice_id_str).await;
    assert_eq!(
        alice_self_after["status"], "online",
        "a hidden user's own client sees their true state"
    );
    // Bob sees her as offline, even though she is still fully connected.
    let bob_view_after = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(
        bob_view_after["status"], "offline",
        "everyone else sees a hidden user as offline"
    );

    // The same asymmetry holds over the REST batch lookup, not just the socket.
    assert_eq!(
        presence_status(&state, &alice_access, &alice_id_str).await,
        "online"
    );
    assert_eq!(
        presence_status(&state, &_bob_access, &alice_id_str).await,
        "offline"
    );
}

/// Presence flips to offline when the last socket closes, not merely when a
/// client says so: this closes the connection abruptly (a plain drop) rather
/// than sending any "I am offline now" message, and confirms both a watching
/// peer and the REST surface observe the transition.
#[tokio::test]
async fn presence_flips_to_offline_when_the_last_socket_closes() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (_alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &_bob_id.to_string()).await;

    let alice_ws = connect(addr, &alice_ticket).await;
    let online = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(online["status"], "online");
    assert_eq!(
        presence_status(&state, &bob_access, &alice_id_str).await,
        "online"
    );

    // Abruptly drop alice's connection: no logout, no "going offline" frame,
    // just the socket disappearing, the way a crash or a lost network would.
    drop(alice_ws);

    let offline = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(offline["status"], "offline");

    support::wait::wait_until_async("REST to agree alice is offline", || async {
        presence_status(&state, &bob_access, &alice_id_str).await == "offline"
    })
    .await;
}

/// One `GET /presence` request naming a hidden user, a plainly visible one,
/// and an id that never existed, all at once: the shape a moderator page or
/// a member list actually sends, and the case a batched visibility lookup
/// could get wrong in a way a single-id test never would (returning the
/// wrong visibility for one id because of how the batch query grouped rows,
/// or dropping a real id when only some in the page have a live row).
#[tokio::test]
async fn a_batch_mixes_hidden_visible_and_absent_ids_correctly() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let (carol_access, carol_ticket, _carol_id) = user_ticket(&store, "carol").await;
    let alice_id_str = alice_id.to_string();
    let bob_id_str = bob_id.to_string();
    let missing = uuid::Uuid::now_v7();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let _ = next_presence_for(&mut alice_ws, &alice_id_str).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &bob_id_str).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;
    let _ = next_presence_for(&mut carol_ws, &_carol_id.to_string()).await;

    let response = http::router(state.clone())
        .oneshot(patch_request(
            "/presence",
            &alice_access,
            json!({ "visibility": "hidden" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let uri = format!("/presence?ids={alice_id_str},{bob_id_str},{missing}");
    let response = http::router(state.clone())
        .oneshot(get_request(&uri, &carol_access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let entries: Vec<Value> = serde_json::from_slice(&body).unwrap();

    assert_eq!(
        entries.len(),
        2,
        "the never-existed id must be absent, not a third entry"
    );
    let by_id = |id: &str| {
        entries
            .iter()
            .find(|e| e["user_id"] == id)
            .unwrap_or_else(|| panic!("no entry for {id}"))
    };
    assert_eq!(
        by_id(&alice_id_str)["status"],
        "offline",
        "hidden to a third-party viewer, even while connected"
    );
    assert_eq!(
        by_id(&bob_id_str)["status"],
        "online",
        "a plainly visible connected user reads through the same batch"
    );
}

/// A user missing from the batch lookup (never existed) is simply absent,
/// the same contract `GET /users` has, rather than an error or a synthesized
/// "offline" entry.
#[tokio::test]
async fn unknown_id_is_simply_absent() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (access, _ticket, _id) = user_ticket(&store, "alice").await;

    let missing = uuid::Uuid::now_v7();
    let response = http::router(state.clone())
        .oneshot(get_request(&format!("/presence?ids={missing}"), &access))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let entries: Vec<Value> = serde_json::from_slice(&body).unwrap();
    assert!(entries.is_empty());
}

/// A ping is activity too, not just a typing refresh: the idle clock used to
/// be reset only inside the typing handler, so a connection that only reads
/// (never types) would sit "away" after ten minutes even while answering
/// pings the whole time.
///
/// The idle threshold is simulated by winding the tracker's clock back
/// directly (`PresenceTracker::touch_at`) rather than waiting ten real
/// minutes; the pong round trip after the ping is what proves the server has
/// already processed the inbound frame (and so already called `touch`) by
/// the time the test reads `is_idle`.
#[tokio::test]
async fn a_ping_resets_the_idle_clock_not_just_typing() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let hub = Hub::new();
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .build();
    let (_access, ticket, id) = user_ticket(&store, "alice").await;

    let addr = serve(state.clone()).await;
    let mut ws = connect(addr, &ticket).await;
    // Her own connect publishes her own presence; drain it before the pong.
    let _ = next_presence_for(&mut ws, &id.to_string()).await;

    let long_ago = Instant::now() - presence::IDLE_TIMEOUT - Duration::from_secs(1);
    hub.presence().touch_at(id, long_ago);
    assert!(
        hub.presence().is_idle(id),
        "the simulated last activity must read as idle before the ping"
    );

    ws.send(WsMessage::Text(json!({ "type": "ping" }).to_string()))
        .await
        .unwrap();
    let pong = read_frame(&mut ws).await;
    assert_eq!(pong["type"], "pong");

    assert!(
        !hub.presence().is_idle(id),
        "a ping must reset the idle clock like a typing refresh already does"
    );
}

/// Idle is purely a function of elapsed time, not an event anything publishes
/// on its own, so nothing used to tell a *different* viewer a connected user
/// went idle: their status read "online" forever to everyone else until some
/// unrelated event happened to touch their row again.
///
/// The poll interval is shortened (`Hub::with_idle_poll_interval`) so the
/// transition is observed in milliseconds; the idle threshold itself is
/// still simulated by winding the tracker's clock back directly, since
/// nothing about the fix needs ten real minutes to pass to prove it.
#[tokio::test]
async fn an_idle_transition_is_announced_to_another_viewer() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let hub = Hub::with_idle_poll_interval(Duration::from_millis(20));
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .build();
    let (_alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &_bob_id.to_string()).await;

    let _alice_ws = connect(addr, &alice_ticket).await;
    let online = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(online["status"], "online");
    let_the_first_tick_pass().await;

    let long_ago = Instant::now() - presence::IDLE_TIMEOUT - Duration::from_secs(1);
    hub.presence().touch_at(alice_id, long_ago);

    let away = next_presence_for(&mut bob_ws, &alice_id_str).await;
    assert_eq!(
        away["status"], "away",
        "another viewer must be told when a connected user goes idle, not just alice herself"
    );
}

/// The idle watcher must publish nothing at all for somebody appearing
/// offline, not merely publish a frame that derives to "offline".
///
/// `status_for` ignores `idle` for every visibility except `Online`, so the
/// derived status would have been right either way. What would not have been
/// right is the frame's existence: it arrives exactly when a hidden user goes
/// quiet and again when they return, so an observer timestamping frames reads
/// their activity pattern off the timing alone. This is the same shape as the
/// typing leak already closed elsewhere, and the status being correct is
/// precisely what makes it easy to miss.
#[tokio::test]
async fn a_hidden_users_idle_transition_is_never_published() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let hub = Hub::with_idle_poll_interval(Duration::from_millis(20));
    let state = support::app::builder(store.clone())
        .hub(hub.clone())
        .build();
    let (_alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob_id) = user_ticket(&store, "bob").await;
    let alice_id_str = alice_id.to_string();

    store
        .set_presence_visibility(alice_id, presence::Visibility::Hidden)
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _ = next_presence_for(&mut bob_ws, &bob_id.to_string()).await;

    let _alice_ws = connect(addr, &alice_ticket).await;
    // Her connect still publishes, which predates the idle watcher and is its own question.
    let _ = next_presence_for(&mut bob_ws, &alice_id_str).await;
    let_the_first_tick_pass().await;

    let long_ago = Instant::now() - presence::IDLE_TIMEOUT - Duration::from_secs(1);
    hub.presence().touch_at(alice_id, long_ago);

    let leaked = tokio::time::timeout(Duration::from_millis(400), async {
        loop {
            let frame = read_frame(&mut bob_ws).await;
            if frame["type"] == "presence.changed" && frame["user_id"] == alice_id_str.as_str() {
                return frame;
            }
        }
    })
    .await;
    assert!(
        leaked.is_err(),
        "a hidden user going idle must produce no frame at all; one arrived: {leaked:?}"
    );
}
