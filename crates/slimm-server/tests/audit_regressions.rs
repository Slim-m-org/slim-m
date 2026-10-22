// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Regressions for the 2026-07-29 audit findings, gathered here rather than
//! grown onto the existing suites past the line budget. Reports in a channel
//! that cannot scope its own moderation (a DM, a deleted channel, a user
//! subject) must reach the deployment's moderators, and a retried send whose
//! message was deleted must be the retry it is rather than a 500.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
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
        .find(|c| c.name == "general")
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

/// A report about a message in a DM must reach the deployment's moderators.
///
/// It did not: `list` and `resolve` re-check MANAGE_MESSAGES in the report's
/// own channel, and a DM channel grants that to nobody, so intake returned 200
/// while the report was invisible and unresolvable forever. This is the exact
/// black hole the audit found, in the one place harassment is most private.
#[tokio::test]
async fn a_report_filed_in_a_dm_reaches_the_moderators() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (carol_token, carol_id) = register(&store, "carol").await;

    let bob = UserId(Uuid::parse_str(&bob_id).unwrap());
    let carol = UserId(Uuid::parse_str(&carol_id).unwrap());
    let dm = store.open_dm(bob, carol).await.expect("open dm");
    let message_id = slimm_server::ids::MessageId(Uuid::now_v7());
    store
        .send_message(NewMessage::plain(dm.id, bob, message_id, "abuse"))
        .await
        .expect("send in dm");

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&carol_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message_id.0.to_string(),
                "reason": "reporting my own dm message for the test",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK, "intake accepts it");
    let report_id = json_body(filed).await["id"].as_str().unwrap().to_string();

    let queue = app
        .clone()
        .oneshot(request("GET", "/reports", Some(&admin_token), None))
        .await
        .unwrap();
    let rows = json_body(queue).await;
    assert_eq!(
        rows.as_array().unwrap().len(),
        1,
        "the DM report is in the moderator queue, not a black hole"
    );

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
    assert_eq!(
        closed.status(),
        StatusCode::NO_CONTENT,
        "and a moderator can close it"
    );
}

/// A report about a message in a channel that is later deleted stays visible.
///
/// Same root cause as the DM case: a soft-deleted channel resolves to NONE, so
/// the per-channel re-check dropped the report out of the queue on delete.
#[tokio::test]
async fn a_report_survives_its_channel_being_deleted() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let channel_id = general_channel_id(&store).await;
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let extra = store.create_channel("scratch", "text").await.unwrap();
    let report_id = file_a_report(
        &app,
        &extra.id.to_string(),
        &bob_token,
        &admin_token,
        "worth keeping across a delete",
    )
    .await;

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{}", extra.id),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let queue = app
        .clone()
        .oneshot(request("GET", "/reports", Some(&admin_token), None))
        .await
        .unwrap();
    let rows = json_body(queue).await;
    assert!(
        rows.as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == report_id.as_str()),
        "the report is still in the queue after its channel was deleted"
    );
    let _ = channel_id;
}

/// A `user`-subject report about an id that never named an account is refused.
///
/// It was accepted with no existence check and no foreign key, so the queue
/// could be flooded with reports naming random uuids.
#[tokio::test]
async fn a_report_about_a_nonexistent_user_is_refused() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
    let app = app(store.clone());
    let (bob_token, _bob_id) = register(&store, "bob").await;

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&bob_token),
            Some(json!({
                "subject_kind": "user",
                "subject_id": Uuid::now_v7().to_string(),
                "reason": "nobody by this id exists",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::NOT_FOUND);
}
/// Retrying a send whose message was deleted in between is the retry it is,
/// not a 500.
///
/// The idempotency probe filtered deleted rows out, so the re-send fell through
/// to an INSERT that hit the unique id and mapped to Internal. An honest
/// at-least-once client racing a moderator delete hit this; so could any member
/// deliberately.
#[tokio::test]
async fn retrying_a_deleted_send_is_not_a_500() {
    let (store, _guard) = support::new_store("slimm-reports-test").await;
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

    let uri = format!("/channels/{}/messages", channel.id);
    let message_id = Uuid::now_v7().to_string();
    let send = json!({ "id": message_id, "content": "will be deleted" });

    let first = app
        .clone()
        .oneshot(request("POST", &uri, Some(&token), Some(send.clone())))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

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

    let retry = app
        .clone()
        .oneshot(request("POST", &uri, Some(&token), Some(send)))
        .await
        .unwrap();
    assert_eq!(
        retry.status(),
        StatusCode::OK,
        "a retry of a deleted message returns it, not a 500"
    );
}
