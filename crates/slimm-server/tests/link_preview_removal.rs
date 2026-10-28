// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removing the link-preview cards from one message: the author or a
//! MANAGE_MESSAGES holder may, anyone else is refused, the removal is
//! permanent and idempotent, reads report it, and a live event goes out once.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{builder, json_body, register_token_id as register, request};

fn uri(channel_id: &str, message_id: &str) -> String {
    format!("/channels/{channel_id}/messages/{message_id}/link-previews")
}

async fn status(app: &axum::Router, token: &str, channel: &str, message: &str) -> StatusCode {
    app.clone()
        .oneshot(request("DELETE", &uri(channel, message), Some(token), None))
        .await
        .unwrap()
        .status()
}

async fn removed_flag(app: &axum::Router, token: &str, channel: &str, message: &str) -> Value {
    let page = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel}/messages"),
                Some(token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let found = page
        .as_array()
        .or_else(|| page["messages"].as_array())
        .unwrap()
        .iter()
        .find(|m| m["id"] == message)
        .unwrap()
        .clone();
    found["link_previews_removed"].clone()
}

#[tokio::test]
async fn author_and_moderator_may_remove_but_a_bystander_may_not() {
    let (store, _guard) = support::new_store("slimm-lp-removal").await;
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
    let state = builder(store.clone()).build();
    let mut events = state.hub.subscribe();
    let app = slimm_server::http::router(state);

    let (author, _) = register(&store, "author").await;
    let (bystander, _) = register(&store, "bystander").await;
    let (moderator, moderator_id) = register(&store, "moderator").await;
    store
        .assign_role(UserId(Uuid::parse_str(&moderator_id).unwrap()), mods)
        .await
        .unwrap();
    let channel = store
        .create_channel("links", "text")
        .await
        .unwrap()
        .id
        .to_string();

    let send = |content: &'static str| {
        let app = app.clone();
        let author = author.clone();
        let channel = channel.clone();
        async move {
            json_body(
                app.oneshot(request(
                    "POST",
                    &format!("/channels/{channel}/messages"),
                    Some(&author),
                    Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
                ))
                .await
                .unwrap(),
            )
            .await["id"]
                .as_str()
                .unwrap()
                .to_owned()
        }
    };
    let own = send("see https://example.com/a").await;
    let other = send("see https://example.com/b").await;

    assert_eq!(
        removed_flag(&app, &author, &channel, &own).await,
        json!(false)
    );
    assert_eq!(
        status(&app, &bystander, &channel, &own).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        removed_flag(&app, &author, &channel, &own).await,
        json!(false)
    );

    assert_eq!(
        status(&app, &author, &channel, &own).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        status(&app, &author, &channel, &own).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        status(&app, &moderator, &channel, &other).await,
        StatusCode::NO_CONTENT
    );

    // Everyone sees it, not only the one who removed it.
    assert_eq!(
        removed_flag(&app, &bystander, &channel, &own).await,
        json!(true)
    );
    assert_eq!(
        removed_flag(&app, &bystander, &channel, &other).await,
        json!(true)
    );

    let mut removed = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Event::MessageLinkPreviewsRemoved { message_id, .. } = event {
            removed.push(message_id.to_string());
        }
    }
    assert_eq!(
        removed,
        vec![own, other],
        "one event per message, none for the repeat"
    );
}

#[tokio::test]
async fn an_unknown_message_is_not_found() {
    let (store, _guard) = support::new_store("slimm-lp-removal-404").await;
    let app = support::app::app(store.clone());
    let (token, _) = register(&store, "someone").await;
    let channel = support::app::general_channel_id(&store).await;
    let missing = Uuid::now_v7().to_string();
    assert_eq!(
        status(&app, &token, &channel, &missing).await,
        StatusCode::NOT_FOUND
    );
}
