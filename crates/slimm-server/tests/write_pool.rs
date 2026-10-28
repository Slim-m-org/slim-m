// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Writers waiting for SQLite's write lock must not take the connections the
//! readers need.

use std::time::Duration;

mod support;

#[tokio::test]
async fn queued_writers_leave_the_read_connections_free() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-write-pool").await;
    let mut holder = pool.acquire().await.unwrap();
    sqlx::query("BEGIN IMMEDIATE")
        .execute(&mut *holder)
        .await
        .unwrap();

    let writers: Vec<_> = (0..12)
        .map(|n| {
            let store = store.clone();
            tokio::spawn(async move {
                store
                    .register_account(&format!("writer{n}"), "w", "hash", None)
                    .await
                    .map(|_| ())
            })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let read = tokio::time::timeout(Duration::from_secs(1), store.ping()).await;
    sqlx::query("ROLLBACK").execute(&mut *holder).await.unwrap();
    drop(holder);
    for writer in writers {
        let _ = writer.await;
    }

    assert!(
        read.is_ok(),
        "a read waited behind writers that were waiting for the write lock"
    );
}
