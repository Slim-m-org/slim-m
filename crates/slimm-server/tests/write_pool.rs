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
    support::wait::wait_until("a writer to hold a connection waiting for the lock", || {
        store.pool_stats().in_use >= 2
    })
    .await;

    // Probed throughout rather than once, so writers that pile up late still starve a read.
    let mut starved = false;
    let probing = tokio::time::Instant::now();
    while !starved && probing.elapsed() < Duration::from_millis(300) {
        starved = tokio::time::timeout(Duration::from_secs(1), store.ping())
            .await
            .is_err();
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    sqlx::query("ROLLBACK").execute(&mut *holder).await.unwrap();
    drop(holder);
    for writer in writers {
        let _ = writer.await;
    }

    assert!(
        !starved,
        "a read waited behind writers that were waiting for the write lock"
    );
}
