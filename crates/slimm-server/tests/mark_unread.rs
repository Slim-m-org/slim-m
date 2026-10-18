// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! "Mark as unread": the flag that lives beside the read marker.
//!
//! Its own file because `read_state_sync.rs` reached the review ceiling. The
//! setup is duplicated rather than shared: each integration test binary owns
//! its own fixtures, so there is nowhere to put a common one that both can
//! see without a support module that only these two would use.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http::{self};
use slimm_server::ids::{MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_authed as request};

/// A user, their access token, and a router sharing the store.
struct Fixture {
    store: Store,
    app: Router,
    user_id: UserId,
    token: String,
    _guard: support::TestDbGuard,
}

async fn setup(everyone: Permissions) -> Fixture {
    let (store, _guard) = support::new_store("slimm-unread-test").await;
    store.create_role("everyone", everyone, true).await.unwrap();
    let app = http::router(support::app::state(store.clone()));
    let user = store.create_user("alice", "Alice").await.unwrap();
    let tokens = store.open_session(user.id, "dev").await.unwrap();
    Fixture {
        store,
        app,
        user_id: user.id,
        token: tokens.access_token,
        _guard,
    }
}

#[tokio::test]
async fn marking_unread_records_intent_without_rewinding_the_marker() {
    let f = setup(Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES)).await;
    let channel = f.store.create_channel("general", "text").await.unwrap();
    for i in 0..3 {
        f.store
            .send_message(NewMessage::plain(
                channel.id,
                f.user_id,
                MessageId::generate(),
                &format!("m{i}"),
            ))
            .await
            .unwrap();
    }
    let read_uri = format!("/channels/{}/read", channel.id);
    let unread_uri = format!("/channels/{}/unread", channel.id);

    // Catch up completely.
    let body = json_body(
        f.app
            .clone()
            .oneshot(request(
                "PUT",
                &read_uri,
                &f.token,
                Some(json!({ "seq": 3 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["unread"], 0);
    assert_eq!(body["manually_unread"], false);

    // Mark it unread: the note is recorded and the marker does not move.
    let body = json_body(
        f.app
            .clone()
            .oneshot(request("PUT", &unread_uri, &f.token, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["manually_unread"], true);
    assert_eq!(
        body["last_read_seq"], 3,
        "the marker is monotonic; marking unread must not rewind it",
    );
    assert_eq!(
        body["unread"], 0,
        "no new message arrived, so the count is still honestly zero",
    );

    // It survives a fresh read of the state, so it is stored rather than echoed.
    let body = json_body(
        f.app
            .clone()
            .oneshot(request("GET", &read_uri, &f.token, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["manually_unread"], true);

    // Reading the channel is the undo.
    let body = json_body(
        f.app
            .clone()
            .oneshot(request(
                "PUT",
                &read_uri,
                &f.token,
                Some(json!({ "seq": 3 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["manually_unread"], false);
    assert_eq!(body["last_read_seq"], 3);
}

#[tokio::test]
async fn a_channel_never_opened_can_still_be_marked_unread() {
    let f = setup(Permissions::VIEW_CHANNEL).await;
    let channel = f.store.create_channel("general", "text").await.unwrap();

    // No read_states row exists yet; the mark has to create one.
    let body = json_body(
        f.app
            .clone()
            .oneshot(request(
                "PUT",
                &format!("/channels/{}/unread", channel.id),
                &f.token,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(body["manually_unread"], true);
    assert_eq!(body["last_read_seq"], 0);
}

#[tokio::test]
async fn marking_unread_requires_view() {
    let f = setup(Permissions::NONE).await;
    let channel = f.store.create_channel("general", "text").await.unwrap();
    let response = f
        .app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{}/unread", channel.id),
            &f.token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}
