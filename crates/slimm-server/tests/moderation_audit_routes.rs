// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The audit trail through the real router, not the store directly.
//!
//! `restore_to_space` and `clear_member_timeout` gained an acting-moderator
//! parameter, and `http/members.rs` is the only thing that decides what goes
//! into it. Every other test here reaches the store directly and so passes
//! whatever the test itself chose, which cannot catch the one mistake this
//! layer can make: threading the wrong id.
//!
//! Two moderators again, and the one who lifts is never the one who imposed,
//! so a handler passing the imposing moderator, the subject, or anything else
//! it happens to have in scope reads as wrong rather than as plausible.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::store::Store;
use sqlx::SqlitePool;
use tower::ServiceExt;

mod support;

use support::app::{app, request_authed as request};

/// The founding administrator, a second administrator, and somebody to
/// moderate. Both administrators can act, which is what lets the imposing and
/// the lifting moderator be different people.
async fn people(store: &Store) -> (String, UserId, String, UserId, UserId) {
    let first = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(first.id).await.unwrap();
    let first_token = store
        .open_session(first.id, "cli")
        .await
        .unwrap()
        .access_token;

    let second = store
        .create_account("bram", "Bram", "not-a-real-hash")
        .await
        .unwrap();
    for role in store.list_roles().await.unwrap() {
        if !role.is_everyone {
            store.assign_role(second.id, role.id).await.unwrap();
        }
    }
    let second_token = store
        .open_session(second.id, "cli")
        .await
        .unwrap()
        .access_token;

    let member = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();
    (first_token, first.id, second_token, second.id, member.id)
}

/// The acting moderator on each row, oldest first.
async fn actors(pool: &SqlitePool, subject: UserId) -> Vec<(String, Option<Vec<u8>>)> {
    sqlx::query_as(
        "SELECT action, actor_id FROM moderation_audit_log
         WHERE subject_id = ? ORDER BY id",
    )
    .bind(subject)
    .fetch_all(pool)
    .await
    .expect("read the audit log")
}

fn id_bytes(id: UserId) -> Option<Vec<u8>> {
    Some(id.0.as_bytes().to_vec())
}

#[tokio::test]
async fn the_route_records_the_moderator_who_lifted_the_timeout() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-moderation-audit-routes").await;
    let (first_token, first_id, second_token, second_id, member) = people(&store).await;
    let app = app(store.clone());

    let imposed = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member}/timeout"),
            &first_token,
            Some(json!({ "duration_seconds": 1800, "reason": "cool off" })),
        ))
        .await
        .unwrap();
    assert_eq!(imposed.status(), StatusCode::OK);

    let lifted = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{member}/timeout"),
            &second_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(lifted.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        actors(&pool, member).await,
        vec![
            ("timeout".to_owned(), id_bytes(first_id)),
            ("timeout_cleared".to_owned(), id_bytes(second_id)),
        ],
        "the lift is attributed to whoever called it, not to whoever imposed it"
    );
}

#[tokio::test]
async fn the_route_records_the_moderator_who_restored_the_member() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-moderation-audit-routes").await;
    let (first_token, first_id, second_token, second_id, member) = people(&store).await;
    let app = app(store.clone());

    let removed = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/members/{member}/removal"),
            &first_token,
            Some(json!({ "reason": "spam" })),
        ))
        .await
        .unwrap();
    assert_eq!(removed.status(), StatusCode::NO_CONTENT);

    let restored = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{member}/removal"),
            &second_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(restored.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        actors(&pool, member).await,
        vec![
            ("remove".to_owned(), id_bytes(first_id)),
            ("restore".to_owned(), id_bytes(second_id)),
        ],
        "the restore is attributed to whoever called it"
    );
}

/// One member's trail is their own. Trivial SQL, but nothing else asserts it,
/// and a `WHERE subject_id = ?` quietly dropped would make every moderation
/// history show every member's.
#[tokio::test]
async fn one_members_trail_does_not_carry_anothers() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-moderation-audit-routes").await;
    let (first_token, first_id, _second_token, _second_id, member) = people(&store).await;
    let other = store
        .create_account("kit", "Kit", "not-a-real-hash")
        .await
        .unwrap();
    let app = app(store.clone());

    for subject in [member, other.id] {
        let response = app
            .clone()
            .oneshot(request(
                "PUT",
                &format!("/members/{subject}/removal"),
                &first_token,
                Some(json!({ "reason": "spam" })),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    assert_eq!(
        actors(&pool, member).await,
        vec![("remove".to_owned(), id_bytes(first_id))],
        "one row, for this member only"
    );
    assert_eq!(
        actors(&pool, other.id).await,
        vec![("remove".to_owned(), id_bytes(first_id))],
        "and the other member has their own, not a shared one"
    );
}
