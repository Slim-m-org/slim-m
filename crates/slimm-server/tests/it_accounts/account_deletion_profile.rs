// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a deleted account's tombstoned `users` row may still hold.
//!
//! `account_deletion_coverage.rs` only audits columns that reference
//! `users(id)`, so a plain profile column on the row itself is invisible to
//! it; these tests read the raw row instead.

use crate::support;
use slimm_server::ids::UserId;
use slimm_server::store::ProfileUpdate;
use sqlx::Row;

const PROFILE_COLUMNS: [&str; 7] = [
    "status_text",
    "pronouns",
    "about",
    "profile_color",
    "profile_color_rgb",
    "avatar_updated_at",
    "banner_updated_at",
];

async fn profile_cells(pool: &sqlx::SqlitePool, user: UserId) -> Vec<bool> {
    let probes = PROFILE_COLUMNS.map(|c| format!("typeof({c}) <> 'null'"));
    let row = sqlx::query(&format!(
        "SELECT {} FROM users WHERE id = ?",
        probes.join(", ")
    ))
    .bind(user)
    .fetch_one(pool)
    .await
    .expect("raw users row");
    (0..PROFILE_COLUMNS.len())
        .map(|i| row.get::<i64, _>(i) == 1)
        .collect()
}

#[tokio::test]
async fn deleting_an_account_clears_every_free_text_profile_column() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-delete-profile").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();
    store
        .update_profile(
            member.id,
            ProfileUpdate {
                status_text: Some(Some("at the library")),
                pronouns: Some(Some("she/her")),
                about: Some(Some("Nia Example, Springfield")),
                profile_color: Some(3),
                profile_color_rgb: Some(Some(0x00ff_8800)),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    store.set_avatar_updated(member.id).await.unwrap();
    store.set_banner_updated(member.id).await.unwrap();
    assert_eq!(
        profile_cells(&pool, member.id).await,
        vec![true; PROFILE_COLUMNS.len()],
        "every column is set before the deletion"
    );

    store.delete_account(member.id).await.unwrap();

    assert_eq!(
        profile_cells(&pool, member.id).await,
        vec![false; PROFILE_COLUMNS.len()],
        "columns, in order: {PROFILE_COLUMNS:?}"
    );
}

/// A session revoked quietly (a second sign-in from the same install does it)
/// leaves its socket open, and this event is the only thing that closes it.
#[tokio::test]
async fn deleting_an_account_still_names_sessions_revoked_earlier() {
    let (store, _guard) = support::new_store("slimm-delete-sessions").await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();
    let first = store.open_session(member.id, "old").await.unwrap();
    store.open_session(member.id, "new").await.unwrap();
    let first_session = store
        .authenticate(&first.access_token)
        .await
        .unwrap()
        .expect("live token")
        .session_id;
    store.revoke_session(first_session).await.unwrap();

    let revoked = store.delete_account(member.id).await.unwrap();

    assert_eq!(revoked.len(), 2);
    assert!(revoked.contains(&first_session));
}
