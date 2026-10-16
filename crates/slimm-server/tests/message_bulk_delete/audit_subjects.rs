// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Audit rows name only authors whose messages this request deleted, and never
//! the moderator themselves (issue 2053).

use axum::http::StatusCode;

use crate::harness::{app, audit, bulk_delete, channel_id, new_store, people, send};

#[tokio::test]
async fn the_actor_and_already_deleted_authors_get_no_audit_row() {
    let (store, pool, _guard) = new_store().await;
    let (_admin, moderator, member) = people(&store).await;
    let channel = channel_id(&store).await;
    let app = app(store.clone());
    let theirs = send(&app, &channel, &member.0, "spam").await;
    let mine = send(&app, &channel, &moderator.0, "cleanup note").await;

    assert_eq!(
        bulk_delete(&app, &channel, &moderator.0, &[theirs.clone(), mine]).await,
        StatusCode::NO_CONTENT
    );
    let subjects: Vec<_> = audit(&pool).await.into_iter().map(|row| row.2).collect();
    assert_eq!(subjects, vec![Some(member.1.0.as_bytes().to_vec())]);

    let another_of_mine = send(&app, &channel, &moderator.0, "second note").await;
    bulk_delete(&app, &channel, &moderator.0, &[theirs, another_of_mine]).await;
    assert_eq!(
        audit(&pool).await.len(),
        1,
        "a repeat on an already-deleted message moderated nobody new"
    );
}
