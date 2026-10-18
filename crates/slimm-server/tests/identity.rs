// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the server's trust-on-first-use identity: the
//! keypair survives a restart, and the fingerprint it exposes is what a
//! client would actually pin.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::app;

/// A fresh database file, never `:memory:`: the pool hands out multiple
/// connections, and an in-memory database is private to whichever connection
/// created it, so a second connection would see an empty database.
fn temp_db_path() -> (String, support::TestDbGuard) {
    support::TestDbGuard::new("slimm-identity-test")
}

fn config(database_path: String) -> Config {
    Config {
        port: 0,
        database_path,
        hash_concurrency: 2,
        ..Config::default()
    }
}

async fn version_body(store: Store) -> Value {
    let response = app(store)
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn the_identity_keypair_is_stable_across_a_restart() {
    let (path, _guard) = temp_db_path();

    // "First boot": nothing exists yet, so this call generates the keypair.
    let first_pool = db::connect(&config(path.clone()))
        .await
        .expect("connect + migrate");
    let first = Store::new(first_pool)
        .server_identity()
        .await
        .expect("load or create");

    // "Restart": a brand new pool over the same file, standing in for the
    // process exiting and starting again.
    let second_pool = db::connect(&config(path))
        .await
        .expect("reconnect to the same database file");
    let second = Store::new(second_pool)
        .server_identity()
        .await
        .expect("load the persisted identity");

    assert_eq!(
        first.public_key(),
        second.public_key(),
        "the public key must survive a restart, or a client's pin would fire a false alarm on every reboot"
    );
    assert_eq!(first.fingerprint_hex(), second.fingerprint_hex());
}

#[tokio::test]
async fn the_fingerprint_is_deterministic_from_the_same_public_key() {
    let (path, _guard) = temp_db_path();
    let pool = db::connect(&config(path)).await.expect("connect + migrate");
    let store = Store::new(pool);

    let a = store.server_identity().await.unwrap();
    let b = store.server_identity().await.unwrap();
    assert_eq!(a.fingerprint_hex(), b.fingerprint_hex());
    assert_eq!(a.color_strip(), b.color_strip());
}

#[tokio::test]
async fn version_exposes_the_public_key_fingerprint_and_color_strip() {
    let (path, _guard) = temp_db_path();
    let pool = db::connect(&config(path)).await.expect("connect + migrate");
    let store = Store::new(pool);
    let identity = store.server_identity().await.unwrap();

    let body = version_body(store).await;
    let wire = &body["identity"];

    assert_eq!(
        wire["public_key"].as_str().unwrap(),
        base64_standard_encode(&identity.public_key())
    );
    assert_eq!(
        wire["fingerprint"].as_str().unwrap(),
        identity.fingerprint_hex()
    );

    let groups = wire["fingerprint_groups"].as_array().unwrap();
    assert_eq!(groups.len(), 8, "two rows of four in the onboarding design");
    assert_eq!(
        groups
            .iter()
            .map(|g| g.as_str().unwrap())
            .collect::<String>(),
        identity.fingerprint_hex()
    );

    let strip = wire["color_strip"].as_array().unwrap();
    assert_eq!(strip.len(), 4);
    for entry in strip {
        let index = entry.as_u64().unwrap();
        assert!(index < 6, "must index into a six-colour palette");
    }
}

#[tokio::test]
async fn two_deployments_get_different_identities() {
    let (path_a, _guard_a) = temp_db_path();
    let (path_b, _guard_b) = temp_db_path();
    let store_a = Store::new(
        db::connect(&config(path_a))
            .await
            .expect("connect + migrate"),
    );
    let store_b = Store::new(
        db::connect(&config(path_b))
            .await
            .expect("connect + migrate"),
    );

    let a = store_a.server_identity().await.unwrap();
    let b = store_b.server_identity().await.unwrap();
    assert_ne!(
        a.public_key(),
        b.public_key(),
        "each deployment generates its own keypair"
    );
}

/// A tiny local base64 encoder so this test does not need its own dependency
/// on the `base64` crate's engine API just to check what the server already
/// encoded.
fn base64_standard_encode(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}
