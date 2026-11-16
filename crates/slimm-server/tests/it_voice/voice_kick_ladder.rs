// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice kick follows the role ladder's owner rules: the Space owner kicks anyone, and nobody
//! kicks the owner, an administrator holding the owner's own top role included.

use axum::Router;
use axum::http::StatusCode;
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

use crate::support;
use support::app::request_bare as request;

fn app(store: Store) -> Router {
    let voice = VoiceService::for_test(
        "http://127.0.0.1:1",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    support::app::builder(store).voice(voice).router()
}

async fn kick(store: &Store, channel: &str, target: UserId, token: &str) -> StatusCode {
    let uri = format!("/channels/{channel}/voice/participants/{target}/kick");
    app(store.clone())
        .oneshot(request("POST", &uri, Some(token)))
        .await
        .unwrap()
        .status()
}

/// alice owns the Space; erin is a second administrator on the same top role.
#[tokio::test]
async fn the_owner_kicks_a_fellow_administrator_who_cannot_kick_the_owner() {
    let (store, _guard) = support::new_store("slimm-voice-kick-ladder").await;
    let alice = store.create_account("alice", "alice", "h").await.unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let erin = store.create_account("erin", "erin", "h").await.unwrap();
    let admin = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap();
    store.assign_role(erin.id, admin.id).await.unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let channel = channel.id.to_string();
    let alice_token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;
    let erin_token = store
        .open_session(erin.id, "cli")
        .await
        .unwrap()
        .access_token;

    assert_eq!(
        kick(&store, &channel, alice.id, &erin_token).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        kick(&store, &channel, erin.id, &alice_token).await,
        StatusCode::SERVICE_UNAVAILABLE,
        "past every guard; the unreachable SFU answers next"
    );
}
