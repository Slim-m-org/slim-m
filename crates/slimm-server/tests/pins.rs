// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Pinned messages: the MANAGE_MESSAGES gate is evaluated per channel rather
//! than off a deployment-wide check, reading the pin list needs only
//! VIEW_CHANNEL, pinning is idempotent, deleting a pinned message clears its
//! pin, and the mutating routes charge a rate limit.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

fn pin_uri(channel_id: &str, message_id: &str) -> String {
    format!("/channels/{channel_id}/messages/{message_id}/pin")
}

/// A role granting MANAGE_MESSAGES still loses in a channel where a per-channel
/// overwrite strips it back off, even though the same role keeps granting it
/// in a channel with no such overwrite. The gate must read the evaluator's
/// per-channel answer, not a deployment-wide bit: a check of that shape was
/// exactly the bug found and fixed for report resolution elsewhere in this
/// project, and pinning must not repeat it.
#[tokio::test]
async fn pinning_needs_manage_messages_evaluated_per_channel() {
    let (store, _guard) = support::new_store("slimm-pins").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let mods = store
        .create_role("mods", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let app = app(store.clone());

    let (bob_token, bob_id) = register(&store, "bob").await;
    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());
    store.assign_role(bob, mods).await.unwrap();

    let channel_a = store.create_channel("channel-a", "text").await.unwrap();
    let channel_b = store.create_channel("channel-b", "text").await.unwrap();
    // Strip MANAGE_MESSAGES back off the mods role, but only in channel_b.
    store
        .set_role_overwrite(
            channel_b.id,
            mods,
            Permissions::NONE,
            Permissions::MANAGE_MESSAGES,
        )
        .await
        .unwrap();

    let msg_a = send(&app, &channel_a.id.to_string(), &bob_token, "in a").await;
    let msg_b = send(&app, &channel_b.id.to_string(), &bob_token, "in b").await;

    let denied = app
        .clone()
        .oneshot(request(
            "PUT",
            &pin_uri(&channel_b.id.to_string(), msg_b["id"].as_str().unwrap()),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        denied.status(),
        StatusCode::FORBIDDEN,
        "the per-channel overwrite must win over the role grant"
    );

    let allowed = app
        .clone()
        .oneshot(request(
            "PUT",
            &pin_uri(&channel_a.id.to_string(), msg_a["id"].as_str().unwrap()),
            Some(&bob_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        allowed.status(),
        StatusCode::NO_CONTENT,
        "the same role must still grant it in a channel with no overwrite"
    );
}

/// Reading the pin list needs only VIEW_CHANNEL: a member holding nothing
/// else can still see what a moderator pinned.
#[tokio::test]
async fn reading_the_pin_list_needs_only_view_channel() {
    let (store, _guard) = support::new_store("slimm-pins").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let mods = store
        .create_role(
            "mods",
            Permissions::SEND_MESSAGES.union(Permissions::MANAGE_MESSAGES),
            false,
        )
        .await
        .unwrap();
    let app = app(store.clone());

    let (mod_token, mod_id) = register(&store, "carol").await;
    store
        .assign_role(UserId(Uuid::parse_str(&mod_id).unwrap()), mods)
        .await
        .unwrap();
    let (plain_token, _plain_id) = register(&store, "dave").await;

    let channel = store.create_channel("general", "text").await.unwrap();
    let posted = send(&app, &channel.id.to_string(), &mod_token, "look at this").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();

    let pinned = app
        .clone()
        .oneshot(request(
            "PUT",
            &pin_uri(&channel.id.to_string(), &message_id),
            Some(&mod_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(pinned.status(), StatusCode::NO_CONTENT);

    // Dave holds only @everyone's VIEW_CHANNEL, nothing more.
    let listed = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/pins", channel.id),
            Some(&plain_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let body = json_body(listed).await;
    let entries = body.as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["id"], message_id);
}

/// Pinning an already-pinned message must not error or create a second row:
/// a double tap on a slow connection is the normal case, the same reasoning
/// reactions and channel overwrites already rely on.
#[tokio::test]
async fn pinning_twice_is_idempotent() {
    let (store, _guard) = support::new_store("slimm-pins").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "pin me").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();
    let uri = pin_uri(&channel.id.to_string(), &message_id);

    for _ in 0..3 {
        let response = app
            .clone()
            .oneshot(request("PUT", &uri, Some(&token), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    let count = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/pins/count", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        count["count"], 1,
        "three pins of the same message must count once"
    );

    let listed = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/pins", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
}

/// Deleting a pinned message must clear its pin, or the pin list and the
/// header's count would keep a dangling reference to content the message
/// list has already hidden - a pin the UI would render as a blank.
#[tokio::test]
async fn deleting_a_pinned_message_removes_its_pin() {
    let (store, _guard) = support::new_store("slimm-pins").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "pin then delete").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();

    let pinned = app
        .clone()
        .oneshot(request(
            "PUT",
            &pin_uri(&channel.id.to_string(), &message_id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(pinned.status(), StatusCode::NO_CONTENT);

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}/messages/{message_id}", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let count = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/pins/count", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        count["count"], 0,
        "the pin must not survive its message's deletion"
    );

    let listed = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{}/pins", channel.id),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed.as_array().unwrap().len(), 0);
}

/// Every other mutating route in this codebase charges a rate limit; pin and
/// unpin must too. `PATCH .../messages/{id}` was missed once already (see
/// CLAUDE.md), so this is checked directly rather than assumed from review.
#[tokio::test]
async fn pin_route_is_rate_limited() {
    let (store, _guard) = support::new_store("slimm-pins").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::MANAGE_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _user) = register(&store, "alice").await;

    let posted = send(&app, &channel.id.to_string(), &token, "rate limit me").await;
    let message_id = posted["id"].as_str().unwrap().to_owned();
    let uri = pin_uri(&channel.id.to_string(), &message_id);

    let mut statuses = Vec::new();
    for _ in 0..60 {
        let response = app
            .clone()
            .oneshot(request("PUT", &uri, Some(&token), None))
            .await
            .unwrap();
        statuses.push(response.status());
    }

    assert!(
        statuses.contains(&StatusCode::NO_CONTENT),
        "the first pins inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained pin flood must be refused: {statuses:?}"
    );
}
