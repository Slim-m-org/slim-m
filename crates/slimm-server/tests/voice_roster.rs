// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading who is in a channel's voice room without having joined it.
//!
//! `mintVoiceToken`'s tests (`tests/voice.rs`) can drive a real 200 without a
//! reachable SFU, because minting is pure local signing. Listing participants
//! is a genuine round trip, so this file stands up a stand-in LiveKit room
//! service the same way `push_endpoints.rs` stands up a stand-in relay, and
//! drives the real handler against it.

use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

fn app(store: Store, voice: VoiceService) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice,
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    builder.body(Body::empty()).unwrap()
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

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built through the store: these tests are about
/// the roster route, not the registration route.
async fn member(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let access = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (access, account.id.to_string())
}

/// Answers every `ListParticipants` call with a fixed body, so the shape and
/// filtering logic get exercised against a real, if canned, response.
async fn spawn_room_service(participants: Value) -> String {
    async fn answer(State(body): State<Value>) -> Json<Value> {
        Json(body)
    }
    let router = Router::new()
        .route("/twirp/livekit.RoomService/ListParticipants", post(answer))
        .with_state(json!({ "participants": participants }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

/// A loopback address nothing can be listening on: connecting to it fails
/// fast and locally, with no DNS lookup and no dependence on outbound network
/// access, unlike pointing at a real unreachable hostname would.
///
/// A privileged port rather than a freed ephemeral one. This used to bind
/// port zero, read the address back and drop the listener, which left a port
/// that merely happened to be free: the operating system is then free to hand
/// that same port to the next mock room service this suite starts, and the
/// unreachable SFU becomes reachable. That is a race, it needs no unusual
/// timing to lose, and it was losing about one full `cargo test --all` in
/// three. Binding below 1024 needs a capability no test process has, so
/// nothing here can take this one.
fn unreachable_url() -> String {
    "http://127.0.0.1:1".to_owned()
}

fn voice_at(url: &str) -> VoiceService {
    VoiceService::for_test(url, "APItestkey", "a-test-secret-of-at-least-32-characters")
}

#[tokio::test]
async fn seeing_the_channel_is_what_the_roster_needs() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&spawn_room_service(json!([])).await);
    let app = app(store.clone(), voice);
    let (token, _) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "seeing who is in a room requires seeing the channel at all"
    );
}

#[tokio::test]
async fn a_channel_that_does_not_exist_refuses_like_one_you_cannot_view() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&spawn_room_service(json!([])).await);
    let app = app(store.clone(), voice);
    let (token, _) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", uuid::Uuid::now_v7()),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "a nonexistent channel must not be distinguishable from a forbidden one"
    );
}

#[tokio::test]
async fn the_roster_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    let channel = store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&spawn_room_service(json!([])).await);
    let app = app(store, voice);

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_text_only_deployment_says_so_instead_of_pretending() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    // No SFU configured, which is a supported way to run this.
    let app = app(store.clone(), VoiceService::disabled());
    let (token, _) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::NOT_IMPLEMENTED,
        "a client should hide the roster, not retry it forever"
    );
    assert_eq!(
        json_body(response).await["error"],
        "this server has no voice configured"
    );
}

#[tokio::test]
async fn an_unreachable_sfu_answers_service_unavailable_not_an_empty_room() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&unreachable_url());
    let app = app(store.clone(), voice);
    let (token, _) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::SERVICE_UNAVAILABLE,
        "an unreachable SFU is not the same claim as a room with nobody in it"
    );
}

#[tokio::test]
async fn a_room_nobody_has_joined_yet_is_an_empty_list() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&spawn_room_service(json!([])).await);
    let app = app(store.clone(), voice);
    let (token, _) = member(&store, "alice").await;

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await["participants"], json!([]));
}

/// The security property this whole route exists to get right: a participant
/// who chose appear-offline must not become visible through the preview shown
/// before joining, even though the SFU itself does report them as connected.
#[tokio::test]
async fn a_hidden_participant_is_omitted_from_everyone_elses_roster_but_their_own() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let (alice_token, _) = member(&store, "alice").await;
    let (bob_token, bob_id) = member(&store, "bob").await;
    let (carol_token, carol_id) = member(&store, "carol").await;

    let voice = voice_at(
        &spawn_room_service(json!([
            { "identity": bob_id, "name": "bob" },
            { "identity": carol_id, "name": "carol" },
        ]))
        .await,
    );
    let app = app(store.clone(), voice);

    let hide = app
        .clone()
        .oneshot(patch_request(
            "/presence",
            &bob_token,
            json!({ "visibility": "hidden" }),
        ))
        .await
        .unwrap();
    assert_eq!(hide.status(), StatusCode::OK);

    let alice_view = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/voice/roster", channel.id),
                Some(&alice_token),
            ))
            .await
            .unwrap(),
    )
    .await;
    let alice_names: Vec<&str> = alice_view["participants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["display_name"].as_str().unwrap())
        .collect();
    assert_eq!(
        alice_names,
        vec!["carol"],
        "a third party never sees a hidden participant in the preview"
    );

    let bob_view = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/voice/roster", channel.id),
                Some(&bob_token),
            ))
            .await
            .unwrap(),
    )
    .await;
    let mut bob_names: Vec<&str> = bob_view["participants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["display_name"].as_str().unwrap())
        .collect();
    bob_names.sort_unstable();
    assert_eq!(
        bob_names,
        vec!["bob", "carol"],
        "a hidden user still sees their own true presence, same as everywhere else"
    );

    let carol_view = json_body(
        app.oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&carol_token),
        ))
        .await
        .unwrap(),
    )
    .await;
    let carol_names: Vec<&str> = carol_view["participants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["display_name"].as_str().unwrap())
        .collect();
    assert_eq!(carol_names, vec!["carol"], "unaffected by bob's choice");
}

#[tokio::test]
async fn the_roster_reports_the_call_age_from_the_earliest_listed_join() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let (token, alice_id) = member(&store, "alice").await;
    let (_, bob_id) = member(&store, "bob").await;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let voice = voice_at(
        &spawn_room_service(json!([
            { "identity": bob_id, "name": "bob", "joinedAtMs": (now_ms - 60_000).to_string() },
            { "identity": alice_id, "name": "alice", "joinedAtMs": (now_ms - 7_000).to_string() },
        ]))
        .await,
    );
    let app = app(store.clone(), voice);

    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let age = json_body(response).await["call_age_ms"].as_i64().unwrap();
    assert!(
        (60_000..70_000).contains(&age),
        "the age is the earliest join's, not the viewer's own: {age}"
    );
}

#[tokio::test]
async fn an_empty_room_has_no_call_age() {
    let (store, _guard) = support::new_store("slimm-voice-roster-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let voice = voice_at(&spawn_room_service(json!([])).await);
    let app = app(store.clone(), voice);
    let (token, _) = member(&store, "alice").await;
    let response = app
        .oneshot(request(
            "GET",
            &format!("/channels/{}/voice/roster", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert!(json_body(response).await["call_age_ms"].is_null());
}
