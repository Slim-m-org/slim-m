// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The DM list's unread counts across more than one conversation.
//!
//! Its own file rather than another case in `dms.rs`, which is already at its
//! allowlisted line budget: the batched `list_dm_conversations` reads every
//! conversation's unread in one grouped query, and the risk that a batch
//! introduces - one channel's count leaking onto another - only shows with two
//! conversations carrying different counts, which the single-conversation case
//! in `dms.rs` cannot see.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn open_dm(app: &Router, token: &str, target_id: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/dms/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/channels/{channel_id}/messages"),
            Some(token),
            Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

async fn list_dms(app: &Router, token: &str) -> Vec<Value> {
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/dms", Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    listed.as_array().unwrap().clone()
}

/// Two conversations with different unread counts must each keep their own,
/// mapped to their own participant. This is the case the single-conversation
/// test in `dms.rs` cannot see and the batched grouped query could get wrong:
/// a mis-join would leak one channel's count onto another.
#[tokio::test]
async fn dm_list_keeps_each_conversation_unread_count_distinct() {
    let (store, _guard) = support::new_store("slimm-dm-unread-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let (carol_token, carol_id) = register(&store, "carol").await;

    let with_bob = open_dm(&app, &alice_token, &bob_id).await;
    let bob_channel = with_bob["channel_id"].as_str().unwrap().to_owned();
    let with_carol = open_dm(&app, &alice_token, &carol_id).await;
    let carol_channel = with_carol["channel_id"].as_str().unwrap().to_owned();

    // Three unread from bob, one from carol.
    send(&app, &bob_channel, &bob_token, "b1").await;
    send(&app, &bob_channel, &bob_token, "b2").await;
    send(&app, &bob_channel, &bob_token, "b3").await;
    let carol_last = send(&app, &carol_channel, &carol_token, "c1").await;

    let conversations = list_dms(&app, &alice_token).await;
    assert_eq!(conversations.len(), 2);
    let by_channel = |id: &str| {
        conversations
            .iter()
            .find(|c| c["channel_id"] == id)
            .unwrap_or_else(|| panic!("conversation {id} missing from the list"))
    };
    assert_eq!(by_channel(&bob_channel)["unread"], 3);
    assert_eq!(by_channel(&bob_channel)["user"]["id"], bob_id);
    assert_eq!(by_channel(&carol_channel)["unread"], 1);
    assert_eq!(by_channel(&carol_channel)["user"]["id"], carol_id);

    // Reading carol's clears only carol's; bob's three are untouched.
    let carol_seq = carol_last["seq"].as_i64().unwrap();
    app.clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{carol_channel}/read"),
            Some(&alice_token),
            Some(json!({ "seq": carol_seq })),
        ))
        .await
        .unwrap();

    let relisted = list_dms(&app, &alice_token).await;
    let find = |id: &str| relisted.iter().find(|c| c["channel_id"] == id).unwrap();
    assert_eq!(
        find(&carol_channel)["unread"],
        0,
        "reading carol must clear only carol"
    );
    assert_eq!(
        find(&bob_channel)["unread"],
        3,
        "bob's unread must be untouched by reading carol"
    );
}
