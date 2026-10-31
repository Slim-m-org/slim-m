// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Joining a channel's voice room.
//!
//! The token this endpoint returns is a bearer credential the SFU trusts, so
//! what it grants has to be decided from the caller's permissions in that
//! channel and nowhere else. These drive the route; the token's own shape is
//! covered by the unit tests in `src/voice.rs`.

use axum::Router;
use axum::http::StatusCode;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::Value;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_bare as request};

fn app(store: Store, voice: VoiceService) -> Router {
    support::app::builder(store).voice(voice).router()
}

fn enabled_voice() -> VoiceService {
    VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

fn claims_of(token: &str) -> Value {
    let payload = token.split('.').nth(1).expect("a jwt has three parts");
    serde_json::from_slice(&BASE64URL.decode(payload).expect("base64url")).expect("json")
}

/// A member with a session, built through the store: these tests are about the
/// voice gate, not the registration route.
async fn member(store: &Store, username: &str) -> String {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token
}

#[tokio::test]
async fn connect_is_what_gets_you_a_token() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    // @everyone can see the channel but not connect to it.
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());
    let token = member(&store, "alice").await;

    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::FORBIDDEN,
        "seeing a channel is not the same as being allowed into its voice room"
    );
}

#[tokio::test]
async fn a_listener_gets_a_token_that_cannot_publish() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());
    let token = member(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;

    assert_eq!(body["can_publish"], false);
    assert_eq!(body["room"], format!("channel-{}", channel.id));
    assert_eq!(body["url"], "wss://livekit.example.com");

    let claims = claims_of(body["token"].as_str().unwrap());
    assert_eq!(claims["video"]["roomJoin"], true);
    assert_eq!(claims["video"]["canSubscribe"], true);
    assert_eq!(
        claims["video"]["canPublish"], false,
        "the SFU has to enforce listen-only, not the client"
    );
    assert_eq!(
        claims["video"]["room"],
        format!("channel-{}", channel.id),
        "the token is scoped to the channel that was authorized"
    );
}

#[tokio::test]
async fn speak_rights_carry_into_the_token() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::CONNECT)
                .union(Permissions::SPEAK),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());
    let token = member(&store, "alice").await;

    let body = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{}/voice/token", channel.id),
                Some(&token),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["can_publish"], true);
    assert_eq!(
        claims_of(body["token"].as_str().unwrap())["video"]["canPublish"],
        true
    );
}

/// The evaluator already covers precedence; this pins that the voice route
/// reads the per-channel answer rather than the base one, which is the mistake
/// that would let somebody muted in one room join it anyway.
#[tokio::test]
async fn a_channel_denying_connect_beats_the_role_that_grants_it() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::CONNECT)
                .union(Permissions::SPEAK),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .set_role_overwrite(
            channel.id,
            everyone,
            Permissions::NONE,
            Permissions::CONNECT,
        )
        .await
        .unwrap();

    let app = app(store.clone(), enabled_voice());
    let token = member(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_channel_that_does_not_exist_refuses_like_one_you_cannot_join() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());
    let token = member(&store, "alice").await;

    let missing = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", uuid::Uuid::now_v7()),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        missing.status(),
        StatusCode::FORBIDDEN,
        "a nonexistent channel must not be distinguishable from a forbidden one"
    );
}

#[tokio::test]
async fn a_text_only_deployment_says_so_instead_of_pretending() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    // No SFU configured, which is a supported way to run this.
    let app = app(store.clone(), VoiceService::disabled());
    let token = member(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", channel.id),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::NOT_IMPLEMENTED,
        "a client should hide voice, not retry it forever"
    );
    assert_eq!(
        json_body(response).await["error"],
        "this server has no voice configured"
    );
}

#[tokio::test]
async fn a_token_requires_authentication() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store, enabled_voice());

    let response = app
        .oneshot(request(
            "POST",
            &format!("/channels/{}/voice/token", channel.id),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

/// A minted token cannot be revoked, so eviction is what makes a kick take
/// effect now rather than whenever the token lapses. That makes the permission
/// gate in front of it the whole security property, and it went untested for
/// as long as the route did not exist.
#[tokio::test]
async fn kicking_needs_kick_members_in_that_channel() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    // Enough to join a room, deliberately not enough to remove anyone from it.
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), enabled_voice());

    let token = member(&store, "alice").await;
    let target = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();

    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, target.id
            ),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::FORBIDDEN,
        "being allowed into a room is not being allowed to throw people out"
    );
}

// See tests/voice_kick_escalation.rs: kick above your own level, per channel.

/// A text-only deployment answers plainly enough for a client to hide the
/// control, rather than failing as though something went wrong.
#[tokio::test]
async fn kicking_without_an_sfu_says_so() {
    let (store, _guard) = support::new_store("slimm-voice-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::CONNECT)
                .union(Permissions::KICK_MEMBERS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone(), VoiceService::disabled());

    let token = member(&store, "alice").await;
    let target = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    // alice outranks bob by role, so the kick reaches the voice service.
    let alice = store.authenticate(&token).await.unwrap().unwrap().user_id;
    let mods = store
        .create_role("mods", Permissions::NONE, false)
        .await
        .unwrap();
    store.reorder_roles(&[mods]).await.unwrap();
    store.assign_role(alice, mods).await.unwrap();

    let response = app
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, target.id
            ),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
}
