// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Account deletion is a tombstone `UPDATE`, never a `DELETE FROM users`, so
//! every `ON DELETE SET NULL` authorship column in the schema is a promise
//! only `delete_account`'s own explicit anonymization statements can keep.
//! These tests pin that promise per column family; split out of `account.rs`
//! in the change that pushed it over the 500-line ceiling.

mod support;
use support::reports::StoreReportExt;

use slimm_server::ids::{EmojiId, MessageId};
use slimm_server::store::{NewMessage, Store};

async fn new_store() -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-anon");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

/// `Report.reporter_id`'s own doc comment promises it is "null once the
/// reporter's account has been anonymized", and until this was fixed no code
/// path ever made that true.
///
/// The column carries `ON DELETE SET NULL`, which never fires: deleting an
/// account here is a tombstone `UPDATE`, never a `DELETE FROM users`, so the
/// constraint has nothing to trigger on. Every other authorship column is
/// cleared explicitly; this pair was simply missed.
#[tokio::test]
async fn delete_account_anonymizes_a_report_the_deleted_user_filed() {
    let (store, _pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let reporter = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();
    let subject = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    store
        .file_report(
            reporter.id,
            slimm_server::store::ReportSubject::Message(subject),
            "not ok",
        )
        .await
        .unwrap();

    let before = store.list_open_reports(None, &[], 50).await.unwrap();
    assert_eq!(
        before.first().expect("one open report").reporter_id,
        Some(reporter.id),
        "the report must name its reporter before the account is deleted, or \
         this test proves nothing"
    );

    store.delete_account(reporter.id).await.unwrap();

    let after = store.list_open_reports(None, &[], 50).await.unwrap();
    assert_eq!(
        after
            .first()
            .expect("the report itself survives")
            .reporter_id,
        None,
        "the deleted account must not still be named as the reporter"
    );
}

/// The same promise `delete_account_anonymizes_a_report_the_deleted_user_filed`
/// pins, on the three sibling columns the 2026-08-11 review found still open:
/// `member_timeouts.issued_by`, `space_removals.removed_by` and
/// `polls.created_by` all carry an `ON DELETE SET NULL` that can never fire
/// (deletion is a tombstone `UPDATE`), and `removed_by` is served live on the
/// wire via `RemovalDto`, so a deleted moderator's id persisted forever.
#[tokio::test]
async fn delete_account_anonymizes_a_pin_and_an_uploaded_emoji() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();

    let message = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    store.pin_message(channel, message, bob.id).await.unwrap();
    // custom_emoji.sha256 has an FK onto attachments, so the bytes must exist first.
    let sha = vec![7u8; 32];
    sqlx::query(
        "INSERT INTO attachments (sha256, size, content_type, created_at) VALUES (?, 1, 'image/png', 0)",
    )
    .bind(&sha)
    .execute(&pool)
    .await
    .unwrap();
    let emoji_id = EmojiId::generate();
    store
        .create_custom_emoji(emoji_id, "party", &sha, Some(bob.id))
        .await
        .unwrap()
        .unwrap();

    store.delete_account(bob.id).await.unwrap();

    let pinned_by: Option<Vec<u8>> =
        sqlx::query_scalar("SELECT pinned_by FROM pinned_messages WHERE message_id = ?")
            .bind(message)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        pinned_by, None,
        "schema/openapi.yaml says pinned_by reads null once the account is anonymized"
    );

    let uploader: Option<Vec<u8>> =
        sqlx::query_scalar("SELECT uploader_id FROM custom_emoji WHERE id = ?")
            .bind(emoji_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        uploader, None,
        "schema/openapi.yaml says uploader_id is null once the uploader's account is deleted"
    );
}

#[tokio::test]
async fn delete_account_anonymizes_moderation_and_poll_authorship() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let moderator = store
        .create_account("mod", "Mod", "not-a-real-hash")
        .await
        .unwrap();
    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();
    let carol = store
        .create_account("carol", "Carol", "not-a-real-hash")
        .await
        .unwrap();

    store
        .set_member_timeout(bob.id, i64::MAX, None, moderator.id)
        .await
        .unwrap();
    store
        .remove_from_space(carol.id, moderator.id, Some("spam"))
        .await
        .unwrap();
    let poll_message = MessageId::generate();
    store
        .send_poll_message(
            channel,
            moderator.id,
            poll_message,
            "vote",
            slimm_server::store::NewPoll {
                question: "lunch?",
                options: &["yes".into(), "no".into()],
                close_at: None,
            },
        )
        .await
        .unwrap();

    let timeout = store.member_timeout(bob.id).await.unwrap().unwrap();
    let removal = &store.list_removals().await.unwrap()[0];
    let poll = store
        .poll_for_message(poll_message, admin.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        timeout.issued_by,
        Some(moderator.id),
        "fixture must name the issuer"
    );
    assert_eq!(
        removal.removed_by,
        Some(moderator.id),
        "fixture must name the remover"
    );
    assert_eq!(
        poll.created_by,
        Some(moderator.id),
        "fixture must name the creator"
    );
    let audited: Vec<Option<Vec<u8>>> =
        sqlx::query_scalar("SELECT actor_id FROM moderation_audit_log ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        audited.len(),
        2,
        "the timeout and the removal are both logged"
    );
    assert!(
        audited.iter().all(Option::is_some),
        "fixture must name the actor of both audited acts"
    );

    store.delete_account(moderator.id).await.unwrap();

    let timeout = store.member_timeout(bob.id).await.unwrap().unwrap();
    let removal = &store.list_removals().await.unwrap()[0];
    let poll = store
        .poll_for_message(poll_message, admin.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        timeout.issued_by, None,
        "a deleted issuer must be anonymized"
    );
    assert_eq!(
        removal.removed_by, None,
        "a deleted remover must be anonymized"
    );
    assert_eq!(
        poll.created_by, None,
        "a deleted poll creator must be anonymized"
    );
    let audited: Vec<Option<Vec<u8>>> =
        sqlx::query_scalar("SELECT actor_id FROM moderation_audit_log ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        audited.len(),
        2,
        "and the acts themselves are still recorded"
    );
    assert!(
        audited.iter().all(Option::is_none),
        "a deleted moderator must not stay named in the audit trail either"
    );
}
