// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! End-to-end coverage for `ChannelCreated`, `ChannelUpdated`, `ChannelDeleted`
//! and `OverwriteChanged`, half of the 2026-07-30 audit's fan-out finding that
//! was missing entirely (`hub.publish` never appeared in `http/channels.rs` or
//! `http/overwrites.rs`). See `live_role_events.rs` for the role half.
//!
//! Create, update and overwrite reach a connection under the same
//! current-permission channel check `message.created` already uses.
//! `ChannelDeleted` is the one that cannot: once a channel is gone, asking
//! "can you view it right now" answers no for everyone, so it is gated on
//! having viewed it a moment before instead (see
//! [`slimm_server::store::Store::viewed_channel_before_delete`]).

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn state_for(store: &Store) -> AppState {
    AppState {
        store: store.clone(),
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    }
}

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

/// Reads the next text frame as JSON, skipping `presence.changed`: every
/// connect in this file publishes one on the same shared hub these tests
/// assert against, and it is real chatter no test here is checking.
///
/// Bounded rather than a bare loop: a missing publish must fail this test
/// fast with a clear panic, not hang the runner forever waiting for a frame
/// that will never come.
async fn read_frame(ws: &mut Client) -> Value {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            match ws.next().await {
                Some(Ok(WsMessage::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    if frame["type"] == "presence.changed" {
                        continue;
                    }
                    return frame;
                }
                Some(Ok(_)) => continue,
                other => panic!("expected a text frame, got {other:?}"),
            }
        }
    })
    .await
    .expect("timed out waiting for a frame")
}

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            builder.body(Body::from(value.to_string())).unwrap()
        }
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// Grants ADMINISTRATOR to a user so every test below can create, rename, and
/// delete channels and set or clear overwrites without wiring up every bit
/// each verb happens to need.
async fn make_admin(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn channel_created_reaches_only_current_viewers() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    // No VIEW_CHANNEL in `@everyone`: bob is the "cannot view it" control.
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(req(
            "POST",
            "/channels",
            &alice_access,
            Some(json!({ "name": "announcements" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "channel.created");
    assert_eq!(frame["channel"]["name"], "announcements");

    let bob_next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut bob_ws)).await;
    assert!(
        bob_next.is_err(),
        "bob cannot view any channel and must not learn one was created"
    );
}

#[tokio::test]
async fn channel_updated_reaches_only_current_viewers() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    // Denied before bob connects, so the deny itself sends him no frame.
    store
        .set_member_overwrite(
            channel.id,
            bob,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let uri = format!("/channels/{}", channel.id);
    let response = http::router(state.clone())
        .oneshot(req(
            "PATCH",
            &uri,
            &alice_access,
            Some(json!({ "topic": "read me" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "channel.updated");
    assert_eq!(frame["channel"]["topic"], "read me");

    let bob_next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut bob_ws)).await;
    assert!(
        bob_next.is_err(),
        "bob was denied view of this channel and must not learn it changed"
    );
}

/// The case the ordinary channel-scoped check cannot answer: once a channel
/// is gone, asking "can you view it right now" answers no for everyone, which
/// is exactly why this event needs its own gate
/// ([`slimm_server::store::Store::viewed_channel_before_delete`]). If that
/// special case regresses back to the ordinary check, this fails for alice
/// and bob both, not just carol.
#[tokio::test]
async fn channel_deleted_reaches_everyone_who_could_view_it_a_moment_before() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    // A second live channel: deleting the deployment's last one is refused.
    let _keep = store.create_channel("keep", "text").await.unwrap();
    let doomed = store.create_channel("doomed", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let (_carol_access, carol_ticket, carol) = user_ticket(&store, "carol").await;
    make_admin(&store, alice).await;

    // Carol never held view of the channel about to be deleted.
    store
        .set_member_overwrite(
            doomed.id,
            carol,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;
    let mut carol_ws = connect(addr, &carol_ticket).await;

    let uri = format!("/channels/{}", doomed.id);
    let response = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    for ws in [&mut alice_ws, &mut bob_ws] {
        let frame = read_frame(ws).await;
        assert_eq!(frame["type"], "channel.deleted");
        assert_eq!(frame["channel_id"], doomed.id.to_string());
    }

    let carol_next =
        tokio::time::timeout(Duration::from_millis(300), read_frame(&mut carol_ws)).await;
    assert!(
        carol_next.is_err(),
        "carol never viewed the deleted channel and must not be told either"
    );
}

#[tokio::test]
async fn overwrite_changed_reaches_only_current_viewers() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;
    let (_carol_access, _carol_ticket, carol) = user_ticket(&store, "carol").await;
    make_admin(&store, alice).await;

    // Denied before bob connects; see `channel_updated`'s identical note.
    store
        .set_member_overwrite(
            channel.id,
            bob,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    let addr = serve(state.clone()).await;
    let mut alice_ws = connect(addr, &alice_ticket).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // A no-op overwrite on an uninvolved third member: only the event matters here.
    let uri = format!("/channels/{}/overwrites/member/{}", channel.id, carol);
    let response = http::router(state.clone())
        .oneshot(req(
            "PUT",
            &uri,
            &alice_access,
            Some(json!({ "allow": 0, "deny": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    // Checked on both set and clear: each is its own publish site.
    let frame = read_frame(&mut alice_ws).await;
    assert_eq!(frame["type"], "overwrite.changed");
    assert_eq!(frame["channel_id"], channel.id.to_string());

    let clear = http::router(state.clone())
        .oneshot(req("DELETE", &uri, &alice_access, None))
        .await
        .unwrap();
    assert_eq!(clear.status(), StatusCode::NO_CONTENT);
    assert_eq!(read_frame(&mut alice_ws).await["type"], "overwrite.changed");

    let bob_next = tokio::time::timeout(Duration::from_millis(300), read_frame(&mut bob_ws)).await;
    assert!(
        bob_next.is_err(),
        "bob was denied view of this channel and must not learn its overwrites changed"
    );
}

/// The overwrite that revokes somebody's view reaches *them*, which is the
/// whole symptom this event exists to fix.
///
/// Gating on the ordinary per-viewer check alone answers one instant too late:
/// the connection whose view this very write removed now fails it, so the
/// frame goes to everybody except the person it was about, and their rail
/// keeps showing a channel they can no longer open until they reconnect. The
/// event carries who could see the channel a moment before, which leaks
/// nothing - every id in it is somebody who could already see it - and the
/// frame itself carries only the channel id.
#[tokio::test]
async fn an_overwrite_that_revokes_view_reaches_the_person_it_revoked() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let state = state_for(&store);

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    // Bob can view it right now; this request is what takes that away.
    let uri = format!("/channels/{}/overwrites/member/{}", channel.id, bob);
    let response = http::router(state.clone())
        .oneshot(req(
            "PUT",
            &uri,
            &alice_access,
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let frame = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut bob_ws))
        .await
        .expect("bob must be told his own view was revoked");
    assert_eq!(frame["type"], "overwrite.changed");
    assert_eq!(frame["channel_id"], channel.id.to_string());
    assert!(
        frame.get("allow").is_none() && frame.get("deny").is_none(),
        "the frame says a channel changed, never what the overwrite was: {frame}"
    );
}

/// A category carries no permission of its own (see docs/decisions/
/// 0006-channel-categories.md), so its change reaches every connection with
/// no view check at all, unlike every other event in this file. Bob holds no
/// `VIEW_CHANNEL` anywhere and still learns a category changed - the
/// property that fails if `CategoryChanged` is ever folded into the
/// channel-scoped match instead of the deployment-wide one.
#[tokio::test]
async fn category_changed_reaches_a_connection_with_no_view_permission_at_all() {
    let (store, _guard) = support::new_store("slimm-live-channel-events-test").await;
    store
        .create_role("everyone", Permissions::SEND_MESSAGES, true)
        .await
        .unwrap();
    let state = state_for(&store);

    let (alice_access, _alice_ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    make_admin(&store, alice).await;

    let addr = serve(state.clone()).await;
    let mut bob_ws = connect(addr, &bob_ticket).await;

    let response = http::router(state.clone())
        .oneshot(req(
            "POST",
            "/categories",
            &alice_access,
            Some(json!({ "name": "extras" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let frame = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut bob_ws))
        .await
        .expect("bob must be told a category changed despite holding no VIEW_CHANNEL");
    assert_eq!(frame["type"], "category.changed");
}
