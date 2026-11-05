// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /voice-notifications/channels` and `PUT /voice-notifications/channels/{id}` (decision 0107).

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;

mod support;

use support::app::{call_as, register_account, router};

#[tokio::test]
async fn a_choice_round_trips_and_off_clears_it() {
    let (store, _guard) = support::new_store("slimm-voice-notify-prefs").await;
    let alice = register_account(&store, "alice").await;
    let lounge = store.create_channel("lounge", "voice").await.unwrap().id;
    let app = router(store);
    let uri = format!("/voice-notifications/channels/{lounge}");

    let (status, body) = call_as(
        &app,
        "GET",
        "/voice-notifications/channels",
        &alice.token,
        None,
    )
    .await;
    assert_eq!((status, body), (StatusCode::OK, json!([])));

    let (status, body) = call_as(
        &app,
        "PUT",
        &uri,
        &alice.token,
        Some(json!({ "joins": "first", "streams": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["joins"], "first");

    let (_, listed) = call_as(
        &app,
        "GET",
        "/voice-notifications/channels",
        &alice.token,
        None,
    )
    .await;
    assert_eq!(
        listed,
        json!([{ "channel_id": lounge.to_string(), "joins": "first", "streams": true }])
    );

    let (status, _) = call_as(
        &app,
        "PUT",
        &uri,
        &alice.token,
        Some(json!({ "joins": "off", "streams": false })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, listed) = call_as(
        &app,
        "GET",
        "/voice-notifications/channels",
        &alice.token,
        None,
    )
    .await;
    assert_eq!(listed, json!([]));
}

#[tokio::test]
async fn only_a_voice_channel_and_a_known_mode_are_accepted() {
    let (store, _guard) = support::new_store("slimm-voice-notify-prefs").await;
    let alice = register_account(&store, "alice").await;
    let text = store.create_channel("chat", "text").await.unwrap().id;
    let voice = store.create_channel("lounge", "voice").await.unwrap().id;
    let app = router(store);
    let on = json!({ "joins": "every", "streams": false });

    let (status, _) = call_as(
        &app,
        "PUT",
        &format!("/voice-notifications/channels/{text}"),
        &alice.token,
        Some(on.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = call_as(
        &app,
        "PUT",
        &format!("/voice-notifications/channels/{voice}"),
        &alice.token,
        Some(json!({ "joins": "sometimes", "streams": false })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_channel_the_caller_cannot_see_is_refused() {
    let (store, _guard) = support::new_store("slimm-voice-notify-prefs").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let _owner = register_account(&store, "owner").await;
    let bob = register_account(&store, "bob").await;
    let voice = store.create_channel("lounge", "voice").await.unwrap().id;
    store
        .set_member_overwrite(voice, bob.id, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
    let app = router(store);

    let (status, _) = call_as(
        &app,
        "PUT",
        &format!("/voice-notifications/channels/{voice}"),
        &bob.token,
        Some(json!({ "joins": "every", "streams": false })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn it_needs_a_session() {
    let (store, _guard) = support::new_store("slimm-voice-notify-prefs").await;
    let app = router(store);
    let (status, _) =
        support::app::call(&app, "GET", "/voice-notifications/channels", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
