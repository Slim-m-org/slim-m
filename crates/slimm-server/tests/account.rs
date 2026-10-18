// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for account deletion: anonymization, revocation, and the
//! HTTP endpoint.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, OpenError, RefreshOutcome, SendError};
use tower::ServiceExt;

mod support;

#[tokio::test]
async fn delete_account_anonymizes_content_and_revokes_access() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("correct horse battery".to_owned())
        .await
        .unwrap();
    let account = store.create_account("alice", "Alice", &hash).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let tokens = store.open_session(account.id, "laptop").await.unwrap();
    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            account.id,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message;

    // Before: the token works, the message is authored by alice, login exists.
    assert!(
        store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .is_some()
    );
    assert_eq!(
        store.message(message.id).await.unwrap().unwrap().author_id,
        Some(account.id)
    );
    assert!(store.find_credentials("alice").await.unwrap().is_some());

    let revoked = store.delete_account(account.id).await.unwrap();
    assert_eq!(revoked.len(), 1, "the one open session is revoked");

    // The access token no longer resolves and refresh is denied.
    assert!(
        store
            .authenticate(&tokens.access_token)
            .await
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        store.rotate_refresh(&tokens.refresh_token).await.unwrap(),
        RefreshOutcome::Denied
    ));

    // The account cannot log in (tombstoned) and the username frees up.
    assert!(store.find_credentials("alice").await.unwrap().is_none());
    assert!(
        store
            .create_account("alice", "New Alice", "x")
            .await
            .is_ok(),
        "the freed username can be registered again"
    );

    // The message survives in the channel, but authorship is cleared.
    let message = store.message(message.id).await.unwrap().unwrap();
    assert_eq!(message.content, "hello");
    assert_eq!(message.author_id, None);
}

#[tokio::test]
async fn open_session_refuses_a_deleted_account() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    let account = store
        .create_account("alice", "Alice", "hash")
        .await
        .unwrap();
    store.delete_account(account.id).await.unwrap();

    // Even resolving the tombstoned user, a login cannot open a fresh session,
    // so a login racing the deletion cannot escape it.
    let result = store.open_session(account.id, "device").await;
    assert!(matches!(result, Err(OpenError::AccountGone)));
}

#[tokio::test]
async fn delete_account_purges_member_channel_overwrites() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let account = store
        .create_account("alice", "Alice", "hash")
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    store
        .set_member_overwrite(
            channel.id,
            account.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    // While the account exists, its member overwrite denies view.
    assert!(
        !store
            .has_permission(account.id, channel.id, Permissions::VIEW_CHANNEL)
            .await
            .unwrap()
    );

    store.delete_account(account.id).await.unwrap();

    // The member overwrite row is purged, so it no longer affects evaluation.
    assert!(
        store
            .has_permission(account.id, channel.id, Permissions::VIEW_CHANNEL)
            .await
            .unwrap()
    );
}

/// The uploader rows a deletion is supposed to purge are private database
/// state with no public read path, so the proof is behavioral: linking bytes
/// alice genuinely uploaded works while her account exists, and stops
/// working the moment it is deleted, with nothing else in reach to grant her
/// the right back (no role, no view access to a channel that has it).
#[tokio::test]
async fn delete_account_removes_attachment_uploader_rows() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    let channel = store.create_channel("general", "text").await.unwrap();
    let alice = store
        .create_account("alice", "Alice", "hash")
        .await
        .unwrap();

    let sha256 = vec![0x42u8; 32];
    store
        .store_attachment(&sha256, 8, "image/png", "photo.png", Some(alice.id))
        .await
        .unwrap();

    // While the account exists, having uploaded the bytes is enough to link them.
    store
        .send_message(NewMessage {
            channel_id: channel.id,
            author_id: alice.id,
            id: MessageId::generate(),
            content: "before",
            attachment_ids: std::slice::from_ref(&sha256),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await
        .expect("alice can link bytes she uploaded");

    store.delete_account(alice.id).await.unwrap();

    // Nothing left grants the right back; see this test's doc comment.
    let result = store
        .send_message(NewMessage {
            channel_id: channel.id,
            author_id: alice.id,
            id: MessageId::generate(),
            content: "after",
            attachment_ids: std::slice::from_ref(&sha256),
            spoiler_ids: &[],
            reply_to_id: None,
            forward: None,
        })
        .await;
    assert!(
        matches!(result, Err(SendError::AttachmentNotFound)),
        "expected AttachmentNotFound, got {result:?}"
    );
}

#[tokio::test]
async fn http_delete_account_rejects_the_token_afterward() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    let app = support::app::router(store);

    // Register and grab the access token.
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "username": "bob",
                        "display_name": "Bob",
                        "password": "hunter2hunter2",
                        "device_name": "cli"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let access = json["access_token"].as_str().unwrap().to_owned();

    // Delete the account.
    let deleted = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {access}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "password": "hunter2hunter2" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    // The same token is now rejected everywhere.
    let after = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/auth/ws-ticket")
                .header("authorization", format!("Bearer {access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(after.status(), StatusCode::UNAUTHORIZED);
}

/// The last administrator cannot delete themselves out of a deployment other
/// people are still using: roles, invites and moderation all need a bit nobody
/// would hold afterwards, and there is no recovery path from that state.
#[tokio::test]
async fn the_last_administrator_cannot_strand_a_populated_deployment() {
    let (store, _guard) = support::new_store("slimm-account-test").await;
    let app = support::app::router(store);

    let signup = |username: &'static str, invite: Option<String>| {
        let app = app.clone();
        async move {
            let mut body = json!({
                "username": username,
                "display_name": username,
                "password": "hunter2hunter2",
                "device_name": "cli"
            });
            if let Some(code) = invite {
                body["invite_code"] = json!(code);
            }
            let response = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/auth/register")
                        .header("content-type", "application/json")
                        .body(Body::from(body.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            json["access_token"].as_str().unwrap().to_owned()
        }
    };

    // The first account claims the deployment and becomes its administrator.
    let admin = signup("admin", None).await;

    // A second, ordinary member: somebody who would be stranded. Joining a
    // claimed deployment takes an invite, so the admin issues one.
    let created = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/invites")
                .header("authorization", format!("Bearer {admin}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(created.into_body(), usize::MAX)
        .await
        .unwrap();
    let invite: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let code = invite["code"].as_str().unwrap().to_owned();

    let _member = signup("member", Some(code)).await;

    let refused = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/account")
                .header("authorization", format!("Bearer {admin}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "password": "hunter2hunter2" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        refused.status(),
        StatusCode::CONFLICT,
        "deleting the only administrator while others remain must be refused, and as a \
         conflict rather than a server error"
    );

    // The account is still usable, not left half-deleted.
    let still_working = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/channels")
                .header("authorization", format!("Bearer {admin}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(still_working.status(), StatusCode::OK);
}
