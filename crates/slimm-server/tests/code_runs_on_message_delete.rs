// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Migration 0068's `code_runs_on_message_delete` trigger. Messages are only
//! ever tombstoned, so the table's `ON DELETE CASCADE` never fires; without the
//! trigger a deleted message's shared code output (up to 64 KiB a block)
//! stayed behind for good, the one message-child table the retention sweep
//! could not reclaim.

mod support;

use slimm_server::ids::MessageId;
use slimm_server::store::{CodeRunRecord, NewMessage, Store};
use sqlx::SqlitePool;

async fn new_store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-code-runs-delete");
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
async fn soft_deleting_a_message_drops_its_code_runs() {
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
    assert_eq!(
        runs_for(&pool, message).await,
        2,
        "fixture must have runs to drop"
    );

    store.delete_message(message, admin.id).await.unwrap();

    assert_eq!(
        runs_for(&pool, message).await,
        0,
        "a tombstoned message keeps no shared code output behind"
    );
}
