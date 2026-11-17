// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A heart sent with or without U+FE0F is one reaction under the picker's own
//! form, on add, remove and the reactor list, and rows stored before that are
//! folded together by [`slimm_server::http::rekey_stored_reactions`].

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::support;
use support::app::{app, json_body, register_token as register, request};

const BARE_HEART: &str = "%E2%9D%A4";
const EMOJI_HEART: &str = "%E2%9D%A4%EF%B8%8F";

async fn reactions(app: &Router, token: &str, channel: &str) -> Value {
    let listed = json_body(
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
    listed.as_array().unwrap()[0]["reactions"].clone()
}

async fn react(app: &Router, token: &str, method: &str, message: &str, emoji: &str) {
    let uri = format!("/messages/{message}/reactions/{emoji}");
    let response = app
        .clone()
        .oneshot(request(method, &uri, Some(token), None))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::NO_CONTENT,
        "{method} {emoji}"
    );
}

#[tokio::test]
async fn a_heart_with_and_without_vs16_is_one_reaction() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-reaction-vs16").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    let channel = store
        .create_channel("general", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let bob = register(&store, "bob").await;
    let message = Uuid::now_v7().to_string();
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel}/messages"),
            Some(&alice),
            Some(json!({ "id": message, "content": "react" })),
        ))
        .await
        .unwrap();

    react(&app, &alice, "PUT", &message, BARE_HEART).await;
    react(&app, &bob, "PUT", &message, EMOJI_HEART).await;
    let listed = reactions(&app, &alice, &channel).await;
    assert_eq!(listed.as_array().unwrap().len(), 1, "{listed}");
    assert_eq!(listed[0]["emoji"], "\u{2764}\u{FE0F}");
    assert_eq!(listed[0]["count"], 2);

    let reactors = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/messages/{message}/reactions/{BARE_HEART}"),
                Some(&alice),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(reactors["users"].as_array().unwrap().len(), 2, "{reactors}");

    react(&app, &bob, "DELETE", &message, BARE_HEART).await;
    assert_eq!(reactions(&app, &alice, &channel).await[0]["count"], 1);

    // Rows from before the fold: one bare, one qualified for alice, which the rekey merges.
    let message_blob = Uuid::parse_str(&message).unwrap();
    sqlx::query("UPDATE reactions SET emoji = ? WHERE message_id = ?")
        .bind("\u{2764}")
        .bind(message_blob)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO reactions (message_id, user_id, emoji, created_at) \
         SELECT message_id, user_id, ?, created_at + 1 FROM reactions WHERE message_id = ?",
    )
    .bind("\u{2764}\u{FE0F}")
    .bind(message_blob)
    .execute(&pool)
    .await
    .unwrap();
    react(&app, &bob, "PUT", &message, BARE_HEART).await;
    assert_eq!(
        reactions(&app, &alice, &channel)
            .await
            .as_array()
            .unwrap()
            .len(),
        2
    );

    slimm_server::http::rekey_stored_reactions(&store)
        .await
        .unwrap();
    let listed = reactions(&app, &alice, &channel).await;
    assert_eq!(listed.as_array().unwrap().len(), 1, "{listed}");
    assert_eq!(listed[0]["emoji"], "\u{2764}\u{FE0F}");
    assert_eq!(listed[0]["count"], 2);
}
