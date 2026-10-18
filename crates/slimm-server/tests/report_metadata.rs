// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Report metadata: who wrote the reported content, and what the caller can
//! do about it in `channel_id`. Split from `reports.rs` (queue lifecycle and
//! gating) once it crossed the 500-line hard limit; see
//! docs/decisions/0011-per-channel-permissions.md for `channel_permissions`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
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

/// Sends a message as `author_token` and files a report on it as
/// `reporter_token`, returning the report id.
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

/// The queue names who wrote the reported message.
///
/// It could not be read off the report: `subject_id` for a message report is
/// the *message's* id, not its author's, and nothing else on the row or on any
/// served route said who wrote it - so a moderator was asked for an
/// irreversible close on content with no author attached. The DTO carries
/// `subject_author_id`, joined at read time, because a report names a message
/// id and the authorship of that id does not change; only its content does,
/// which is what the snapshot is for.
#[tokio::test]
async fn the_queue_names_the_reported_messages_author() {
    let (store, _guard) = support::new_store("slimm-report-metadata-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, _bob_id) = register(&store, "bob").await;
    let channel_id = general_channel_id(&store).await;

    let _report_id = file_a_report(&app, &channel_id, &admin_token, &bob_token, "reported").await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let report = &listed.as_array().unwrap()[0];
    assert_eq!(
        report["subject_author_id"].as_str().unwrap(),
        admin_id,
        "alice wrote the reported message, and the queue has to say so"
    );
    assert_ne!(
        report["subject_author_id"], report["subject_id"],
        "the author is not the message id, which is what made this unreadable"
    );
}

/// A report about a user carries no author, because there is no message, and
/// no `channel_permissions` either, because there is no channel to compute
/// them in. Both nulls the client renders as "nothing to show" rather than a
/// lookup still in flight.
#[tokio::test]
async fn a_user_report_carries_no_subject_author_or_channel_permissions() {
    let (store, _guard) = support::new_store("slimm-report-metadata-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&admin_token),
            Some(json!({
                "subject_kind": "user",
                "subject_id": bob_id,
                "reason": "not okay",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let report = &listed.as_array().unwrap()[0];
    assert!(report["subject_author_id"].is_null());
    assert!(
        report["channel_permissions"].is_null(),
        "a channel-less report has nothing to compute permissions in"
    );
}

/// A DM report's `channel_permissions` can never carry MANAGE_MESSAGES, even
/// for the deployment's own administrator: nobody holds that permission in a
/// DM, no matter what role they hold elsewhere. This is the sharpest finding
/// docs/decisions/0011-per-channel-permissions.md names this field for - a
/// DM harassment report's "Delete message" action must never read as
/// available when the server can never grant it.
#[tokio::test]
async fn a_dm_reports_channel_permissions_never_carries_manage_messages() {
    let (store, _guard) = support::new_store("slimm-report-metadata-test").await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let admin = UserId(Uuid::parse_str(&admin_id).unwrap());
    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());
    let dm = store.open_dm(admin, bob).await.unwrap();

    let report_id = file_a_report(
        &app,
        &dm.id.to_string(),
        &bob_token,
        &admin_token,
        "a dm message",
    )
    .await;

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let report = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == report_id)
        .expect("the report just filed is in the queue");
    let bits = Permissions::from_bits(report["channel_permissions"].as_i64().unwrap());
    assert!(
        bits.contains(Permissions::VIEW_CHANNEL),
        "the admin is a participant of this DM, so they can view it"
    );
    assert!(
        !bits.contains(Permissions::MANAGE_MESSAGES),
        "a DM must never carry MANAGE_MESSAGES, administrator or not"
    );
}
