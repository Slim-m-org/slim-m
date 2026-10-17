// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Concurrent requests that read before they write must queue, not fail.
//!
//! A deferred `BEGIN` that read first and then asked for the write lock was
//! refused at once when another connection held it, and the caller saw a 500
//! "database is locked". The store now opens every writing transaction with
//! `Store::begin_write`; these drive two of the paths that used to fail.

use axum::http::StatusCode;
use slimm_server::store::Store;

mod support;
mod totp_support;

use totp_support::{enrol_and_confirm, login_for_challenge, member, new_store, verify};

const RACERS: usize = 8;

/// No file in the server opens a transaction with the pool's own `begin`.
///
/// `Store::begin_write` and `Store::begin_read` are the two doors, so whether
/// a transaction may write is said where it opens rather than discovered
/// under load.
#[test]
fn every_transaction_says_whether_it_writes() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut offenders = Vec::new();
    let mut pending = vec![src.clone()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).expect("read src") {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            // store.rs is where the two doors themselves are defined.
            if path.extension().is_none_or(|ext| ext != "rs") || path == src.join("store.rs") {
                continue;
            }
            let source = std::fs::read_to_string(&path).expect("read source");
            let code: String = support::code_only(&source)
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect();
            if code.contains("pool.begin()") || code.contains("pool.begin_with(") {
                offenders.push(path.strip_prefix(&src).unwrap().display().to_string());
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "these open a transaction straight from the pool; use Store::begin_write, \
         or Store::begin_read when nothing in it writes: {offenders:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revoking_one_webhook_from_many_requests_at_once_never_errors() {
    let (store, _auth, _guard) = new_store("slimm-concurrent-revoke").await;
    let admin = store.create_user("admin", "Admin").await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;

    for round in 0..5 {
        let hook = store
            .create_webhook(channel, &format!("hook-{round}"), admin.id)
            .await
            .unwrap();
        let racers: Vec<_> = (0..RACERS)
            .map(|_| {
                let store: Store = store.clone();
                let id = hook.webhook.id;
                tokio::spawn(async move { store.revoke_webhook(id, admin.id).await })
            })
            .collect();
        let mut revoked = 0;
        for racer in racers {
            let outcome = racer.await.unwrap();
            assert!(outcome.is_ok(), "a concurrent revoke failed: {outcome:?}");
            revoked += usize::from(outcome.unwrap());
        }
        assert_eq!(revoked, 1, "exactly one request removes the webhook");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn spending_one_recovery_code_on_many_challenges_at_once_is_never_a_500() {
    let (store, auth, _guard) = new_store("slimm-concurrent-totp").await;
    let (token, _) = member(&store, &auth, "ana").await;
    let app = totp_support::app(store, auth);
    let (_secret, recovery) = enrol_and_confirm(&app, &token).await;

    let mut challenges = Vec::new();
    for _ in 0..RACERS {
        challenges.push(login_for_challenge(&app, "ana").await);
    }
    let racers: Vec<_> = challenges
        .into_iter()
        .map(|challenge| {
            let app = app.clone();
            let code = recovery[0].clone();
            tokio::spawn(async move { verify(&app, &challenge, &code).await.status() })
        })
        .collect();
    let mut statuses = Vec::new();
    for racer in racers {
        statuses.push(racer.await.unwrap());
    }

    assert!(
        !statuses.iter().any(axum::http::StatusCode::is_server_error),
        "a concurrent verify answered with a server error: {statuses:?}"
    );
    let accepted = statuses.iter().filter(|s| **s == StatusCode::OK).count();
    assert_eq!(accepted, 1, "one recovery code signs in once: {statuses:?}");
}
