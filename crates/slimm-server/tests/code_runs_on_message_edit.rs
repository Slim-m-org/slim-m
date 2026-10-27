// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Editing a message that already has shared code-run output. Nothing cleared
//! `code_runs` on an edit before this: the row is keyed on `(message_id,
//! block_index)`, and the client looks a run up by that same key when it
//! renders a fenced block, so an edit that changes the code left the old run
//! on screen, attached to the new block, with no indication it was stale.
//!
//! Follows `code_runs_on_message_delete.rs`'s shape: `edit_message` is
//! exercised directly at the store layer rather than through HTTP, since the
//! bug and its fix both live in the store transaction.

mod support;

use slimm_server::ids::MessageId;
use slimm_server::store::{CodeRunRecord, Edited, NewMessage, Store};
use sqlx::SqlitePool;

async fn new_store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-code-runs-edit");
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

async fn runs_for(pool: &SqlitePool, message: MessageId) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM code_runs WHERE message_id = ?")
        .bind(message)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
async fn editing_a_messages_code_changes_its_stored_run() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let message = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "```js\n1+1\n```",
        ))
        .await
        .unwrap()
        .message
        .id;
    store
        .record_code_run(CodeRunRecord {
            message_id: message,
            block_index: 0,
            module_id: "code-exec",
            command: "run",
            ok: true,
            output: "2",
            ran_by: admin.id,
        })
        .await
        .unwrap();
    assert_eq!(
        runs_for(&pool, message).await,
        1,
        "fixture must have a run to invalidate"
    );

    let edited = store
        .edit_message(message, "```js\n99+1\n```", admin.id)
        .await
        .unwrap();
    let Edited::Edited {
        code_runs_cleared, ..
    } = edited
    else {
        panic!("a real content change must report itself as an edit");
    };
    assert!(
        code_runs_cleared,
        "the store must report that it dropped the stale run"
    );

    assert_eq!(
        runs_for(&pool, message).await,
        0,
        "the old block's honest-looking output must not survive attached to different code"
    );
}

#[tokio::test]
async fn editing_one_block_drops_every_run_in_a_multi_block_message() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let message = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "```js\n1+1\n```\n```js\n2+2\n```",
        ))
        .await
        .unwrap()
        .message
        .id;
    for block in 0..2 {
        store
            .record_code_run(CodeRunRecord {
                message_id: message,
                block_index: block,
                module_id: "code-exec",
                command: "run",
                ok: true,
                output: "ok",
                ran_by: admin.id,
            })
            .await
            .unwrap();
    }
    assert_eq!(runs_for(&pool, message).await, 2);

    // Only the second block's code changes; the whole message still clears.
    let edited = store
        .edit_message(message, "```js\n1+1\n```\n```js\n3+3\n```", admin.id)
        .await
        .unwrap();
    assert!(matches!(
        edited,
        Edited::Edited {
            code_runs_cleared: true,
            ..
        }
    ));

    assert_eq!(
        runs_for(&pool, message).await,
        0,
        "every stored run for the message is dropped, not just the changed block"
    );
}

#[tokio::test]
async fn re_saving_identical_content_keeps_the_run() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    let message = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "```js\n1+1\n```",
        ))
        .await
        .unwrap()
        .message
        .id;
    store
        .record_code_run(CodeRunRecord {
            message_id: message,
            block_index: 0,
            module_id: "code-exec",
            command: "run",
            ok: true,
            output: "2",
            ran_by: admin.id,
        })
        .await
        .unwrap();

    let edited = store
        .edit_message(message, "```js\n1+1\n```", admin.id)
        .await
        .unwrap();
    assert!(
        matches!(edited, Edited::Unchanged(_)),
        "byte-identical content writes nothing, so there is no edit to invalidate against"
    );

    assert_eq!(
        runs_for(&pool, message).await,
        1,
        "a no-op save must not throw away a run that still matches the content"
    );
}
