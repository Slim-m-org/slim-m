// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Plain `q`-only search: matching, permission scoping, deleted-message
//! exclusion, malformed FTS5 syntax, and channel scoping. The operator
//! layer's own tests are in the `operators_*` siblings.

use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

/// A search returns only the messages whose content matches, not everything
/// in the channel.
#[tokio::test]
async fn search_returns_matching_messages_only() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let channel_id = channel.id.to_string();

    send(&app, &channel_id, &token, "the quick brown fox").await;
    send(&app, &channel_id, &token, "a slow red turtle").await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?q=fox"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["content"], "the quick brown fox");
}

/// A deleted message is not returned by search, even though the FTS index
/// still technically carries it until touched again.
#[tokio::test]
async fn search_excludes_deleted_messages() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    let channel_id = channel.id.to_string();

    let sent = send(&app, &channel_id, &token, "unicorns are searchable").await;
    let message_id = sent["id"].as_str().unwrap();

    app.clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{channel_id}/messages/{message_id}"),
            Some(&token),
            None,
        ))
        .await
        .unwrap();

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/channels/{channel_id}/messages/search?q=unicorns"),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(results.as_array().unwrap().len(), 0);
}

/// Searching a channel the caller cannot view is refused exactly like
/// listing it would be, so it cannot be used to probe for a hidden channel.
#[tokio::test]
async fn search_requires_view_permission() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let channel = store.create_channel("private", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages/search?q=anything", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Text that is not FTS5 syntax searches its words instead of failing.
#[tokio::test]
async fn a_query_that_is_not_fts_syntax_searches_its_words() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    // A dangling boolean operator is not valid FTS5 syntax.
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages/search?q=hello%20AND", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

/// An empty query is rejected before ever reaching FTS5.
#[tokio::test]
async fn an_empty_query_is_rejected() {
    let (store, _guard) = new_store().await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{}/messages/search?q=%20%20", channel.id),
            Some(&token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// A search cannot be crafted to pull results from a different channel: the
/// channel restriction is a separate SQL predicate the query text never
/// reaches, so it stays scoped no matter what FTS5 syntax `q` uses.
#[tokio::test]
async fn search_stays_scoped_to_its_own_channel() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel_a = store.create_channel("a", "text").await.unwrap();
    let channel_b = store.create_channel("b", "text").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;

    send(
        &app,
        &channel_a.id.to_string(),
        &token,
        "alpha secret words",
    )
    .await;
    send(
        &app,
        &channel_b.id.to_string(),
        &token,
        "alpha secret words",
    )
    .await;

    let results = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!(
                    "/channels/{}/messages/search?q=alpha%20OR%20secret",
                    channel_a.id
                ),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let results = results.as_array().unwrap();
    assert_eq!(
        results.len(),
        1,
        "only channel A's own message should match"
    );
    assert_eq!(results[0]["channel_id"], channel_a.id.to_string());
}
