// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Report triage: MANAGE_MESSAGES gates both the queue and resolving one, and
//! nobody below that bar ever sees a report's content snapshot.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn general_channel_id(store: &Store) -> String {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .next()
        .expect("bootstrap seeds a general channel")
        .id
        .to_string()
}

/// Sends a message as `token` and files a report on it as `reporter_token`,
/// returning the report id.
async fn file_a_report(
    app: &Router,
    channel_id: &str,
    author_token: &str,
    reporter_token: &str,
    content: &str,
) -> String {
    let sent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/messages"),
                Some(author_token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let message_id = sent["id"].as_str().unwrap();

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(reporter_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message_id,
                "reason": "spam"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    json_body(filed).await["id"].as_str().unwrap().to_owned()
}

// --- Gating ---

#[tokio::test]
async fn listing_and_resolving_require_manage_messages() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let report_id = file_a_report(
        &app,
        &channel_id,
        &bob_token,
        &carol_token,
        "secret content",
    )
    .await;

    let list = app
        .clone()
        .oneshot(request("GET", "/reports", Some(&bob_token), None))
        .await
        .unwrap();
    assert_eq!(list.status(), StatusCode::FORBIDDEN);

    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&bob_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::FORBIDDEN);

    // An administrator (MANAGE_MESSAGES via ADMINISTRATOR) can do both.
    let admin_list = app
        .clone()
        .oneshot(request("GET", "/reports", Some(&admin_token), None))
        .await
        .unwrap();
    assert_eq!(admin_list.status(), StatusCode::OK);
}

// --- Happy path and the queue's lifecycle ---

#[tokio::test]
async fn the_queue_carries_the_snapshot_and_resolving_removes_it() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let report_id = file_a_report(
        &app,
        &channel_id,
        &bob_token,
        &carol_token,
        "the reported text",
    )
    .await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let reports = listed.as_array().unwrap();
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0]["id"], report_id);
    assert_eq!(reports[0]["snapshot"], "the reported text");
    assert_eq!(reports[0]["subject_kind"], "message");
    assert_eq!(reports[0]["reason"], "spam");

    let resolve = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(resolve.status(), StatusCode::NO_CONTENT);

    let after = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        after.as_array().unwrap().is_empty(),
        "a resolved report leaves the open queue"
    );

    // Resolving it again finds nothing left to close.
    let again = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "dismissed" })),
        ))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn resolution_must_be_resolved_or_dismissed() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;
    let report_id = file_a_report(&app, &channel_id, &bob_token, &carol_token, "x").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "ignored" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn resolving_a_nonexistent_report_is_not_found() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let response = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{}", Uuid::now_v7()),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

/// Listing already hides a report from a moderator denied MANAGE_MESSAGES in
/// the channel it came from, because the queue carries the reported content
/// verbatim. Resolving checked only the deployment-wide permission, so that
/// same moderator could still dismiss reports from the one channel they were
/// deliberately kept out of, quietly emptying its queue.
#[tokio::test]
async fn a_report_you_cannot_read_is_one_you_cannot_resolve_either() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let (carol_token, carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;

    // Carol moderates the deployment, but is denied it in this channel.
    let moderator = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let carol = UserId(Uuid::parse_str(&carol_id).unwrap());
    store.assign_role(carol, moderator).await.unwrap();
    let channel = ChannelId(Uuid::parse_str(&channel_id).unwrap());
    store
        .set_member_overwrite(
            channel,
            carol,
            Permissions::NONE,
            Permissions::MANAGE_MESSAGES,
        )
        .await
        .unwrap();

    let report_id = file_a_report(&app, &channel_id, &bob_token, &admin_token, "reported").await;

    // She cannot see it.
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&carol_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        listed.as_array().unwrap().is_empty(),
        "the queue already hides a report from a channel she cannot moderate"
    );

    // And cannot close it either. Answered as missing rather than forbidden, so
    // the endpoint does not confirm the report exists.
    let refused = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&carol_token),
            Some(json!({ "resolution": "dismissed" })),
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::NOT_FOUND);

    // The report is untouched, so a moderator who may act on it still can.
    let closed = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/reports/{report_id}"),
            Some(&admin_token),
            Some(json!({ "resolution": "resolved" })),
        ))
        .await
        .unwrap();
    assert_eq!(closed.status(), StatusCode::NO_CONTENT);
}

// Report metadata (subject_author_id, channel_permissions) is in report_metadata.rs, split off at the 500-line limit.
