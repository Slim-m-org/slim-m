// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Direct messages: a DM channel grants access only to its two participants,
//! never through the deployment's role/overwrite evaluator - so not even
//! ADMINISTRATOR reaches one it is not part of - opening the same pair is
//! idempotent and race-safe under real concurrency, blocking refuses both
//! opening and sending in either direction, a DM never appears in the
//! ordinary channel list, and sync/search behave the same way VIEW_CHANNEL
//! does everywhere else. A DM with yourself is `dms_personal_space.rs`.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

async fn open_dm(app: &Router, token: &str, target_id: &str) -> (StatusCode, Value) {
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
    let status = response.status();
    (status, json_body(response).await)
}

async fn send(app: &Router, channel_id: &str, token: &str, content: &str) -> (StatusCode, Value) {
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
    let status = response.status();
    (status, json_body(response).await)
}

async fn block(app: &Router, token: &str, target_id: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "POST",
            &format!("/blocks/{target_id}"),
            Some(token),
            None,
        ))
        .await
        .unwrap()
        .status()
}

/// The single most important invariant here: a DM does not run through the
/// role/overwrite evaluator, so ADMINISTRATOR - which bypasses everything
/// else in this codebase on purpose - reaches nothing in a DM it was never a
/// participant of. Checked against both reading and sending.
#[tokio::test]
async fn administrator_who_is_not_a_participant_cannot_read_or_send_in_a_dm() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    // The first registration claims the deployment and becomes its admin.
    let (admin_token, _admin_id) = register(&store, "admin").await;
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    // Sanity: this account really does hold ADMINISTRATOR deployment-wide.
    let me = json_body(
        app.clone()
            .oneshot(request("GET", "/me", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let admin_bits = me["permissions"].as_i64().unwrap();
    assert_eq!(
        admin_bits & Permissions::ADMINISTRATOR.bits(),
        Permissions::ADMINISTRATOR.bits(),
        "the first registrant must hold ADMINISTRATOR for this test to mean anything"
    );

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let (status, _) = send(&app, &channel_id, &bob_token, "hi alice").await;
    assert_eq!(status, StatusCode::OK, "a real participant can send");

    let read = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        read.status(),
        StatusCode::FORBIDDEN,
        "ADMINISTRATOR must not be able to read a DM it is not part of"
    );

    let (status, _) = send(&app, &channel_id, &admin_token, "i see everything").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "ADMINISTRATOR must not be able to post into a DM it is not part of"
    );
}

/// Two clients racing to open the same pair for the first time must converge
/// on one channel, not two. Driven with genuinely concurrent requests (both
/// directions of the same pair, fired together), not two requests run one
/// after the other, since a sequential pair would never exercise the race at
/// all.
#[tokio::test]
async fn opening_the_same_dm_concurrently_converges_on_one_channel() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let alice_opens = open_dm(&app, &alice_token, &bob_id);
    let bob_opens = open_dm(&app, &bob_token, &alice_id);
    let ((alice_status, alice_result), (bob_status, bob_result)) =
        tokio::join!(alice_opens, bob_opens);

    assert_eq!(alice_status, StatusCode::OK);
    assert_eq!(bob_status, StatusCode::OK);
    assert_eq!(
        alice_result["channel_id"], bob_result["channel_id"],
        "both directions of the same pair, opened at once, must land on one channel"
    );

    let conversations = store
        .list_dm_conversations(UserId(Uuid::parse_str(&alice_id).unwrap()))
        .await
        .unwrap();
    assert_eq!(
        conversations.len(),
        1,
        "the race must not have left a second channel behind"
    );
}

/// A block in either direction refuses opening from either side, not only
/// from the blocked party's side: a block freezes the pair, not just one
/// half of it.
#[tokio::test]
async fn blocking_refuses_opening_in_either_direction() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    assert_eq!(
        block(&app, &bob_token, &alice_id).await,
        StatusCode::NO_CONTENT
    );

    let (status, _) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "the blocked party must not be able to open the DM"
    );
    let (status, _) = open_dm(&app, &bob_token, &alice_id).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "the blocker must not be able to open it either"
    );
}

/// Blocking after a DM is already open must stop new messages without
/// erasing what was already said: VIEW_CHANNEL survives, SEND_MESSAGES does
/// not, for either party.
#[tokio::test]
async fn blocking_refuses_sending_but_not_reading_after_the_dm_is_open() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let (status, _) = send(&app, &channel_id, &bob_token, "before the block").await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        block(&app, &alice_token, &bob_id).await,
        StatusCode::NO_CONTENT
    );

    let (status, _) = send(&app, &channel_id, &bob_token, "after, from bob").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "the blocked party cannot send"
    );
    let (status, _) = send(&app, &channel_id, &alice_token, "after, from alice").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "the blocker cannot send either"
    );

    let read = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        read.status(),
        StatusCode::OK,
        "a block must not erase the conversation's own history"
    );
    let messages = json_body(read).await;
    assert_eq!(messages.as_array().unwrap().len(), 1);
}

/// A DM channel is not a deployment channel anyone browses into; it must
/// never show up next to `general` in the ordinary channel list.
#[tokio::test]
async fn dm_channel_is_excluded_from_the_ordinary_channel_list() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let dm_channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    let listed = app
        .clone()
        .oneshot(request("GET", "/channels", Some(&alice_token), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let channels = json_body(listed).await;
    let ids: Vec<&str> = channels
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["id"].as_str().unwrap())
        .collect();
    assert!(
        !ids.contains(&dm_channel_id.as_str()),
        "a DM channel must never appear in the ordinary channel list"
    );
}

/// The DM list is what the rail renders: the other participant's profile and
/// the caller's own unread count, updating as messages arrive and are read.
#[tokio::test]
async fn dm_list_reports_the_other_participant_and_the_unread_count() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();

    send(&app, &channel_id, &bob_token, "one").await;
    let (_, second) = send(&app, &channel_id, &bob_token, "two").await;
    let last_seq = second["seq"].as_i64().unwrap();

    let listed = json_body(
        app.clone()
            .oneshot(request("GET", "/dms", Some(&alice_token), None))
            .await
            .unwrap(),
    )
    .await;
    let conversations = listed.as_array().unwrap();
    assert_eq!(conversations.len(), 1);
    assert_eq!(conversations[0]["channel_id"], channel_id);
    assert_eq!(conversations[0]["user"]["id"], bob_id);
    assert_eq!(conversations[0]["unread"], 2);

    let marked = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/read"),
            Some(&alice_token),
            Some(json!({ "seq": last_seq })),
        ))
        .await
        .unwrap();
    assert_eq!(marked.status(), StatusCode::OK);

    let listed_again = json_body(
        app.clone()
            .oneshot(request("GET", "/dms", Some(&alice_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(listed_again.as_array().unwrap()[0]["unread"], 0);
}

/// Sync and search reuse the ordinary channel machinery unchanged: a
/// participant gets their DM's messages from both, and a non-participant
/// gets nothing from either - silently skipped by sync (the same as any
/// channel it cannot view), refused outright by search.
#[tokio::test]
async fn sync_and_search_follow_dm_participation() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;

    let (status, opened) = open_dm(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let channel_id = opened["channel_id"].as_str().unwrap().to_owned();
    send(&app, &channel_id, &bob_token, "a searchable greeting").await;

    let synced = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/sync",
                Some(&alice_token),
                Some(json!({ "scopes": [{ "channel_id": channel_id, "after_seq": 0 }] })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let scopes = synced["scopes"].as_array().unwrap();
    assert_eq!(scopes.len(), 1, "a participant's sync must include the DM");
    assert_eq!(scopes[0]["messages"].as_array().unwrap().len(), 1);

    let carol_synced = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/sync",
                Some(&carol_token),
                Some(json!({ "scopes": [{ "channel_id": channel_id, "after_seq": 0 }] })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert!(
        carol_synced["scopes"].as_array().unwrap().is_empty(),
        "a non-participant's sync must silently skip the DM, like any other channel they cannot view"
    );

    let searched = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages/search?q=greeting"),
            Some(&alice_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(searched.status(), StatusCode::OK);
    assert_eq!(
        json_body(searched).await.as_array().unwrap().len(),
        1,
        "a participant can search their own DM"
    );

    let carol_search = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/channels/{channel_id}/messages/search?q=greeting"),
            Some(&carol_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        carol_search.status(),
        StatusCode::FORBIDDEN,
        "a non-participant must be refused outright by search"
    );
}

/// A DM lives in the `channels` table, so the deployment's channel-management
/// routes can reach one by id unless they exclude it. `list_channels` was
/// written to exclude `dm` from the read path; these cover the two write paths
/// that share the same table, which it did not.
///
/// The damage is not a confidentiality breach - there is no way for a
/// non-participant to learn a DM's id - but deleting one is unrecoverable
/// through the API: `open_dm` then finds a live `dm_channels` row whose channel
/// is soft-deleted and fails for that pair permanently.
///
/// The first account through claims the deployment, so it holds MANAGE_CHANNELS
/// deployment-wide, and it is a participant in the DM. It therefore knows the
/// channel id legitimately, which is what makes this reachable at all.
#[tokio::test]
async fn channel_management_routes_cannot_touch_a_dm() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (admin_token, _admin_id) = register(&store, "admin").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let (status, dm) = open_dm(&app, &admin_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    let dm_id = dm["channel_id"].as_str().unwrap().to_owned();

    let renamed = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/channels/{dm_id}"),
            Some(&admin_token),
            Some(json!({ "name": "renamed", "topic": "seized" })),
        ))
        .await
        .unwrap();
    assert_eq!(
        renamed.status(),
        StatusCode::NOT_FOUND,
        "a DM must not be renameable through the channel routes"
    );

    let deleted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{dm_id}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(
        deleted.status(),
        StatusCode::NOT_FOUND,
        "a DM must not be deletable through the channel routes"
    );

    // The real point: the conversation still opens afterwards (used to 500 forever).
    let (reopened, again) = open_dm(&app, &admin_token, &bob_id).await;
    assert_eq!(reopened, StatusCode::OK);
    assert_eq!(again["channel_id"].as_str().unwrap(), dm_id);
}

/// The last-channel guard counts live channels to refuse deleting the final
/// one. A DM counts as a row in that table, so without a `kind` filter a
/// deployment could delete its only real channel as long as one DM existed,
/// leaving members with nowhere to talk.
#[tokio::test]
async fn a_dm_does_not_let_the_last_real_channel_be_deleted() {
    let (store, _guard) = support::new_store("slimm-dms-test").await;
    let app = app(store.clone());

    let (admin_token, _admin_id) = register(&store, "admin").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (status, _) = open_dm(&app, &admin_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);

    let channels = json_body(
        app.clone()
            .oneshot(request("GET", "/channels", Some(&admin_token), None))
            .await
            .unwrap(),
    )
    .await;
    let only = channels.as_array().unwrap();
    assert_eq!(only.len(), 1, "bootstrap seeds exactly one channel");
    let general = only[0]["id"].as_str().unwrap().to_owned();

    let response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/channels/{general}"),
            Some(&admin_token),
            None,
        ))
        .await
        .unwrap();
    assert_ne!(
        response.status(),
        StatusCode::NO_CONTENT,
        "the last real channel must not be deletable just because a DM exists"
    );
}
