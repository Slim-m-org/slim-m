// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bundled SQLite is built without memory statistics, which otherwise
//! take one process-wide mutex on every allocation and made the server slower
//! on 16 cores than on 8 (#2240). The flag lives in `.cargo/config.toml`, so
//! this fails if a build stops picking it up.

mod support;

#[tokio::test]
async fn sqlite_is_built_without_memory_statistics() {
    let (_store, pool, _guard) = support::new_store_with_pool("slimm-sqlite-flags").await;
    let options: Vec<String> = sqlx::query_scalar("PRAGMA compile_options")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert!(
        options.iter().any(|o| o == "DEFAULT_MEMSTATUS=0"),
        "compile options: {options:?}"
    );
}
