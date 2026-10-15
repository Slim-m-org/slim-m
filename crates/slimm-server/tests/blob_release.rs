// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Releasing attachment bytes and reclaiming leaked ones (issues 2069, 2071,
//! 2076, 2077), against a real database and media root.

use std::time::{Duration, SystemTime};

use slimm_server::blobs::{collect_garbage, release};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::media::{Media, to_hex};
use slimm_server::store::Store;
use sqlx::SqlitePool;

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

async fn world(name: &str) -> (Store, SqlitePool, Media, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, Media::for_tests(), guard)
}

async fn stored(store: &Store, media: &Media, sha: [u8; 32]) -> String {
    let hex = to_hex(&sha);
    media
        .write_attachment(&hex, b"bytes".to_vec())
        .await
        .unwrap();
    store
        .store_attachment(&sha, 5, "image/png", "a.png", None)
        .await
        .unwrap();
    hex
}

#[tokio::test]
async fn a_reupload_between_the_row_sweep_and_the_release_keeps_its_bytes() {
    let (store, pool, media, _guard) = world("slimm-blob-reupload").await;
    let sha = [0xABu8; 32];
    let hex = stored(&store, &media, sha).await;
    sqlx::query("UPDATE attachments SET created_at = created_at - ?")
        .bind(2 * DAY_MS)
        .execute(&pool)
        .await
        .unwrap();

    let freed = store.sweep_orphaned_attachments().await.unwrap();
    assert_eq!(freed, vec![hex.clone()]);
    // The identical upload lands in the gap: the file already exists, so only the row comes back.
    store
        .store_attachment(&sha, 5, "image/png", "a.png", None)
        .await
        .unwrap();
    release(&store, &media, &hex).await;

    assert_eq!(media.read_attachment(&hex).await.unwrap(), b"bytes");
}

#[tokio::test]
async fn a_release_with_no_row_left_unlinks_the_bytes() {
    let (store, pool, media, _guard) = world("slimm-blob-release").await;
    let hex = stored(&store, &media, [0xCDu8; 32]).await;
    sqlx::query("DELETE FROM attachments")
        .execute(&pool)
        .await
        .unwrap();
    release(&store, &media, &hex).await;
    assert!(media.read_attachment(&hex).await.is_err());
}

#[tokio::test]
async fn the_scan_removes_stale_temp_files_and_old_bytes_nothing_points_at() {
    let (store, pool, media, _guard) = world("slimm-blob-scan").await;
    let kept = stored(&store, &media, [0x01u8; 32]).await;
    let leaked = stored(&store, &media, [0x02u8; 32]).await;
    sqlx::query("DELETE FROM attachments WHERE size = 5 AND sha256 = ?")
        .bind([0x02u8; 32].to_vec())
        .execute(&pool)
        .await
        .unwrap();
    let young_leak = stored(&store, &media, [0x03u8; 32]).await;
    sqlx::query("DELETE FROM attachments WHERE sha256 = ?")
        .bind([0x03u8; 32].to_vec())
        .execute(&pool)
        .await
        .unwrap();

    // Two days on: everything written above is past both grace windows, except as noted.
    let later = SystemTime::now() + Duration::from_secs(2 * 24 * 60 * 60);
    let names: Vec<String> = media
        .attachment_files()
        .await
        .unwrap()
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    assert!(names.contains(&leaked) && names.contains(&young_leak));

    let removed = collect_garbage(&store, &media, later).await.unwrap();
    assert_eq!(removed, 2, "the two row-less blobs");
    assert!(
        media.read_attachment(&kept).await.is_ok(),
        "a blob with a row stays"
    );
    assert!(media.read_attachment(&leaked).await.is_err());

    // Measured from now, a blob written a moment ago is inside the grace window.
    let fresh = stored(&store, &media, [0x04u8; 32]).await;
    sqlx::query("DELETE FROM attachments WHERE sha256 = ?")
        .bind([0x04u8; 32].to_vec())
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        collect_garbage(&store, &media, SystemTime::now())
            .await
            .unwrap(),
        0
    );
    assert!(
        media.read_attachment(&fresh).await.is_ok(),
        "bytes may briefly precede their row"
    );
}
