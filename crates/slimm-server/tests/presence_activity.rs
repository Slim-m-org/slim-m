// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Rich-presence activity: it fans out with presence, is refused when
//! malformed or over the cap, is rate limited, and never reaches anyone
//! presence would not (appear-offline, or no live socket).

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::app::request_authed as request;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Creates a user and returns (rest access token, ws connect ticket, user id).
async fn user_ticket(store: &Store, name: &str) -> (String, String, slimm_server::ids::UserId) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket, user.id)
}

async fn serve(state: AppState) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, http::router(state)).await.unwrap();
    });
    addr
}

async fn connect(addr: std::net::SocketAddr, ticket: &str) -> Client {
    let (mut ws, _response) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws.send(WsMessage::Text(
        json!({ "type": "hello", "ticket": ticket, "protocol": 1 }).to_string(),
    ))
    .await
    .unwrap();
    let ack = read_frame(&mut ws).await;
    assert_eq!(ack["type"], "hello");
    ws
}

async fn read_frame(ws: &mut Client) -> Value {
    loop {
        match ws.next().await {
            Some(Ok(WsMessage::Text(text))) => {
                return serde_json::from_str(text.as_str()).unwrap();
            }
            Some(Ok(_)) => continue,
            other => panic!("expected a text frame, got {other:?}"),
        }
    }
}

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

async fn send(state: &AppState, req: Request<Body>) -> StatusCode {
    http::router(state.clone())
        .oneshot(req)
        .await
        .unwrap()
        .status()
}

async fn put_activity(state: &AppState, token: &str, body: Value) -> StatusCode {
    send(
        state,
        request("PUT", "/presence/activity", token, Some(body)),
    )
    .await
}

async fn lookup(state: &AppState, token: &str, target: &str) -> Value {
    let response = http::router(state.clone())
        .oneshot(request(
            "GET",
            &format!("/presence?ids={target}"),
            token,
            None,
        ))
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice::<Vec<Value>>(&bytes)
        .unwrap()
        .remove(0)
}

fn track(title: &str) -> Value {
    json!({ "type": "listening", "title": title, "subtitle": "Artist" })
}

/// Waits for the next presence.changed for `user_id` that satisfies `pred`.
async fn presence_where(ws: &mut Client, user_id: &str, pred: impl Fn(&Value) -> bool) -> Value {
    let outcome = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let frame = next_presence_for(ws, user_id).await;
            if pred(&frame) {
                return frame;
            }
        }
    })
    .await;
    outcome.unwrap_or_else(|_| panic!("no matching presence.changed for {user_id}"))
}

#[tokio::test]
async fn activity_fans_out_and_clears_on_delete_and_on_disconnect() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice = alice_id.to_string();
    let addr = serve(state.clone()).await;

    let mut bob_ws = connect(addr, &bob_ticket).await;
    let alice_ws = connect(addr, &alice_ticket).await;
    presence_where(&mut bob_ws, &alice, |f| f["status"] == "online").await;

    assert_eq!(
        put_activity(&state, &alice_access, track("Song")).await,
        StatusCode::NO_CONTENT
    );
    let frame = presence_where(&mut bob_ws, &alice, |f| f.get("activity").is_some()).await;
    assert_eq!(frame["activity"]["type"], "listening");
    assert_eq!(frame["activity"]["title"], "Song");
    let listed = lookup(&state, &bob_access, &alice).await;
    assert_eq!(listed["activity"]["subtitle"], "Artist");

    let cleared = send(
        &state,
        request("DELETE", "/presence/activity", &alice_access, None),
    )
    .await;
    assert_eq!(cleared, StatusCode::NO_CONTENT);
    presence_where(&mut bob_ws, &alice, |f| f.get("activity").is_none()).await;

    put_activity(&state, &alice_access, track("Again")).await;
    presence_where(&mut bob_ws, &alice, |f| f.get("activity").is_some()).await;
    drop(alice_ws);
    let gone = presence_where(&mut bob_ws, &alice, |f| f["status"] == "offline").await;
    assert!(gone.get("activity").is_none());
    let after = lookup(&state, &bob_access, &alice).await;
    assert!(after.get("activity").is_none());
}

#[tokio::test]
async fn hidden_user_activity_is_invisible_to_others_but_not_to_self() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice = alice_id.to_string();
    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let _alice_ws = connect(addr, &alice_ticket).await;
    presence_where(&mut bob_ws, &alice, |f| f["status"] == "online").await;

    let hidden = send(
        &state,
        request(
            "PATCH",
            "/presence",
            &alice_access,
            Some(json!({ "visibility": "hidden" })),
        ),
    )
    .await;
    assert_eq!(hidden, StatusCode::OK);
    presence_where(&mut bob_ws, &alice, |f| f["status"] == "offline").await;

    put_activity(&state, &alice_access, track("Secret")).await;
    let frame = presence_where(&mut bob_ws, &alice, |_| true).await;
    assert_eq!(frame["status"], "offline");
    assert!(
        frame.get("activity").is_none(),
        "hidden activity leaked over ws"
    );
    assert!(
        lookup(&state, &bob_access, &alice)
            .await
            .get("activity")
            .is_none(),
        "hidden activity leaked over rest"
    );
    let own = lookup(&state, &alice_access, &alice).await;
    assert_eq!(own["activity"]["title"], "Secret");
}

#[tokio::test]
async fn malformed_and_over_long_activity_is_refused() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (access, _ticket, _id) = user_ticket(&store, "alice").await;
    let too_long = "x".repeat(slimm_server::presence_activity::MAX_TEXT_CHARS + 1);
    for body in [
        track(&too_long),
        json!({ "type": "listening", "title": "  " }),
        json!({ "type": "dancing", "title": "x" }),
        json!({ "type": "playing", "title": "x", "art_url": "http://evil.example/a.png" }),
    ] {
        assert_eq!(
            put_activity(&state, &access, body).await,
            StatusCode::BAD_REQUEST
        );
    }
}

const ART: &str = "https://i.scdn.co/image/ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9";

#[tokio::test]
async fn art_and_source_round_trip_for_a_viewer() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (alice_access, alice_ticket, alice_id) = user_ticket(&store, "alice").await;
    let (bob_access, _bob_ticket, _bob_id) = user_ticket(&store, "bob").await;
    let alice = alice_id.to_string();
    let _alice_ws = connect(serve(state.clone()).await, &alice_ticket).await;

    let body = json!({
        "type": "listening", "title": "Song", "subtitle": "Artist",
        "source": "Spotify", "art_url": ART,
    });
    assert_eq!(
        put_activity(&state, &alice_access, body).await,
        StatusCode::NO_CONTENT
    );
    let seen = lookup(&state, &bob_access, &alice).await;
    assert_eq!(seen["activity"]["source"], "Spotify");
    assert_eq!(seen["activity"]["art_url"], ART);
}

#[tokio::test]
async fn art_url_outside_the_allowlist_is_refused() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (access, _ticket, _id) = user_ticket(&store, "alice").await;
    let long_source = "s".repeat(slimm_server::presence_activity::MAX_SOURCE_CHARS + 1);
    for extra in [
        json!({ "art_url": "http://i.scdn.co/image/ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9" }),
        json!({ "art_url": "https://evil.example/image/ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9" }),
        json!({ "art_url": "" }),
        json!({ "source": long_source }),
        json!({ "source": "Fire\nfox" }),
    ] {
        let mut body = json!({ "type": "listening", "title": "x" });
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        assert_eq!(
            put_activity(&state, &access, body.clone()).await,
            StatusCode::BAD_REQUEST,
            "{body}"
        );
    }
}

#[tokio::test]
async fn activity_writes_are_rate_limited() {
    let (store, _guard) = support::new_store("slimm-presence-test").await;
    let state = support::app::builder(store.clone()).hub(Hub::new()).build();
    let (access, _ticket, _id) = user_ticket(&store, "alice").await;
    for n in 0..6 {
        let status = put_activity(&state, &access, track(&format!("t{n}"))).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }
    assert_eq!(
        put_activity(&state, &access, track("one too many")).await,
        StatusCode::TOO_MANY_REQUESTS
    );
}
