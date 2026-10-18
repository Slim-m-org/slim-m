// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `channel_scopes_moderation` (`store/channels.rs`) treated a thread like a
//! DM - opaque, unscoped - instead of resolving it to its parent channel the
//! way every other permission check does. A moderator explicitly denied
//! `MANAGE_MESSAGES` on a channel by overwrite still saw, and could resolve,
//! reports about messages inside that channel's threads: the report queue's
//! per-channel exclusion was never applied to a thread at all.
//!
//! Its own file rather than added to `reports.rs` or `report_paging.rs`,
//! both already near the review budget, and this is a distinct seam: what a
//! thread resolves to, not the queue's paging or its permission floor.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_id_token as register, request};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn send(app: &Router, channel: ChannelId, token: &str, content: &str) -> Value {
    json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages"),
                Some(token),
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap(),
    )
    .await
}

async fn open_thread(app: &Router, channel: ChannelId, message_id: &str, token: &str) -> ChannelId {
    let opened = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel}/messages/{message_id}/thread"),
                Some(token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    ChannelId(Uuid::parse_str(opened["id"].as_str().unwrap()).unwrap())
}

async fn file_report(app: &Router, message_id: &str, token: &str) -> String {
    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message_id,
                "reason": "spam",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    json_body(filed).await["id"].as_str().unwrap().to_owned()
}

async fn queue_ids(app: &Router, token: &str) -> Vec<String> {
    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/reports", Some(token), None))
            .await
            .unwrap(),
    )
    .await;
    listed
        .as_array()
        .unwrap()
        .iter()
        .map(|report| report["id"].as_str().unwrap().to_owned())
        .collect()
}

/// A moderator restricted to nothing in the general channel, holding
/// deployment-wide MANAGE_MESSAGES through a role but denied it there by a
/// member overwrite - the exact shape `reports.rs`'s existing
/// `a_report_you_cannot_read_is_one_you_cannot_resolve_either` already
/// covers for the parent channel itself.
async fn restricted_moderator(store: &Store, channel: ChannelId) -> (UserId, String) {
    let (id, token) = register(store, "carol").await;
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(id, role).await.unwrap();
    store
        .set_member_overwrite(channel, id, Permissions::NONE, Permissions::MANAGE_MESSAGES)
        .await
        .unwrap();
    (id, token)
}

/// The core fix: a report about a reply inside a thread is excluded exactly
/// like one about the parent channel, for a moderator denied there.
#[tokio::test]
async fn a_moderator_denied_on_the_parent_cannot_see_or_resolve_a_thread_report() {
    let (store, _guard) = new_store("slimm-report-thread-denied").await;
    let app = app(store.clone());
    let (admin_id, admin_token) = register(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let (_bob_id, bob_token) = register(&store, "bob").await;
    let (_carol_id, carol_token) = restricted_moderator(&store, channel).await;
    let _ = admin_id;

    let seed = send(&app, channel, &bob_token, "seed").await;
    let seed_id = seed["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, channel, &seed_id, &bob_token).await;
    let reply = send(&app, thread, &bob_token, "reply content").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let report_id = file_report(&app, &reply_id, &admin_token).await;

    assert!(
        !queue_ids(&app, &carol_token).await.contains(&report_id),
        "a report about a thread reply must be hidden the same as one about the parent"
    );

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
        "the report is untouched, so a moderator who may act on it still can"
    );
}

/// The positive case: a moderator who still holds MANAGE_MESSAGES on the
/// parent channel sees a report about one of its threads exactly as they
/// would about the parent channel itself.
#[tokio::test]
async fn a_moderator_who_can_moderate_the_parent_sees_its_thread_reports() {
    let (store, _guard) = new_store("slimm-report-thread-allowed").await;
    let app = app(store.clone());
    let (_admin_id, admin_token) = register(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let (bob_id, bob_token) = register(&store, "bob").await;

    let moderator = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(bob_id, moderator).await.unwrap();

    let seed = send(&app, channel, &bob_token, "seed").await;
    let seed_id = seed["id"].as_str().unwrap().to_owned();
    let thread = open_thread(&app, channel, &seed_id, &bob_token).await;
    let reply = send(&app, thread, &bob_token, "reply content").await;
    let reply_id = reply["id"].as_str().unwrap().to_owned();

    let report_id = file_report(&app, &reply_id, &admin_token).await;

    assert!(
        queue_ids(&app, &bob_token).await.contains(&report_id),
        "a moderator who can moderate the parent must see its thread's reports too"
    );
}

/// The property that must not regress: a moderator restricted on one channel
/// must still see a report with no channel, one about a DM, and one about a
/// since-deleted channel, all on the deployment-wide bit alone - the same
/// three kinds `audit_regressions.rs` already covers for an administrator,
/// now checked against a caller the new per-report loop could plausibly have
/// started hiding them from.
#[tokio::test]
async fn a_restricted_moderator_still_sees_reports_with_no_channel_a_dm_or_a_deleted_channel() {
    let (store, _guard) = new_store("slimm-report-thread-regression").await;
    let app = app(store.clone());
    let (admin_id, admin_token) = register(&store, "alice").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let (carol_id, carol_token) = restricted_moderator(&store, channel).await;
    let (bob_id, bob_token) = register(&store, "bob").await;
    let _ = carol_id;

    // A report about a user carries no channel at all.
    let user_report = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&admin_token),
            Some(json!({
                "subject_kind": "user",
                "subject_id": bob_id.to_string(),
                "reason": "no channel to speak of",
            })),
        ))
        .await
        .unwrap();
    assert_eq!(user_report.status(), StatusCode::OK);
    let user_report_id = json_body(user_report).await["id"]
        .as_str()
        .unwrap()
        .to_owned();

    // A report about a message in a DM.
    let dm = store.open_dm(admin_id, bob_id).await.unwrap();
    let dm_message = store
        .send_message(NewMessage::plain(
            dm.id,
            bob_id,
            slimm_server::ids::MessageId::generate(),
            "dm content",
        ))
        .await
        .unwrap()
        .message;
    let dm_report_id = file_report(&app, &dm_message.id.to_string(), &admin_token).await;

    // A report about a message in a channel that is later deleted.
    let extra = store.create_channel("scratch", "text").await.unwrap();
    let extra_message = send(&app, extra.id, &bob_token, "worth keeping").await;
    let extra_report_id =
        file_report(&app, extra_message["id"].as_str().unwrap(), &admin_token).await;
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

    let seen = queue_ids(&app, &carol_token).await;
    for (label, id) in [
        ("no-channel user report", &user_report_id),
        ("DM report", &dm_report_id),
        ("deleted-channel report", &extra_report_id),
    ] {
        assert!(
            seen.contains(id),
            "{label} must stay visible to a restricted moderator on the deployment-wide bit alone"
        );
    }
}
