// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Confirms the invite usability rule's SQL copy (`spend_invite`'s `WHERE`,
//! in `src/store/invites.rs`) agrees with its Rust copy (the shared
//! `invite_usable` behind `Invite::is_usable`) at the exact boundary of each
//! condition it encodes: a fully spent use limit, an expiry that has just
//! passed, and a revoked code. The two cannot be unified into one
//! implementation (sqlx checks a query's SQL against a literal, not a
//! runtime function call), so this is what would catch them drifting apart.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::UserId;
use slimm_server::store::{RedeemError, Store};

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-invite-usability-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// The Rust-side answer for `code`, read straight off `Invite::is_usable`.
async fn rust_says_usable(s: &Store, code: &str) -> bool {
    s.list_invites(None, None, 100)
        .await
        .unwrap()
        .into_iter()
        .find(|i| i.code == code)
        .expect("invite exists")
        .is_usable(now_ms())
}

/// The SQL-side answer: whether `spend_invite`'s own `WHERE` would have
/// matched, through the one public entry point that runs it with no other
/// side effect worth naming (no account is created).
async fn sql_says_usable(s: &Store, code: &str, user: UserId) -> bool {
    !matches!(
        s.redeem_invite(code, user).await,
        Err(RedeemError::Unusable)
    )
}

#[tokio::test]
async fn exactly_at_max_uses_is_unusable_on_both_paths() {
    let (s, _guard) = store().await;
    let owner = s.create_user("owner", "Owner").await.unwrap();
    let a = s.create_user("a", "A").await.unwrap();
    let b = s.create_user("b", "B").await.unwrap();
    let invite = s
        .create_invite(owner.id, None, Some(1), None)
        .await
        .unwrap();

    // One use left: both agree usable, and spending lands on max_uses.
    assert!(rust_says_usable(&s, &invite.code).await);
    assert!(sql_says_usable(&s, &invite.code, a.id).await);

    // At the boundary now: uses == max_uses. Both paths must refuse.
    let rust_usable = rust_says_usable(&s, &invite.code).await;
    let sql_usable = sql_says_usable(&s, &invite.code, b.id).await;
    assert_eq!(rust_usable, sql_usable, "diverged exactly at max_uses");
    assert!(!rust_usable, "a fully spent invite must not read as usable");
}

#[tokio::test]
async fn exactly_at_expiry_is_unusable_on_both_paths() {
    let (s, _guard) = store().await;
    let owner = s.create_user("owner", "Owner").await.unwrap();
    let user = s.create_user("user", "User").await.unwrap();
    let expires_at = now_ms();
    let invite = s
        .create_invite(owner.id, None, None, Some(expires_at))
        .await
        .unwrap();

    // Time has moved past `expires_at`, so `expiry > now` is false on both.
    let rust_usable = rust_says_usable(&s, &invite.code).await;
    let sql_usable = sql_says_usable(&s, &invite.code, user.id).await;
    assert_eq!(rust_usable, sql_usable, "diverged exactly at expiry");
    assert!(
        !rust_usable,
        "an invite expiring exactly now must not be usable"
    );
}

#[tokio::test]
async fn a_revoked_invite_is_unusable_on_both_paths() {
    let (s, _guard) = store().await;
    let owner = s.create_user("owner", "Owner").await.unwrap();
    let user = s.create_user("user", "User").await.unwrap();
    let invite = s.create_invite(owner.id, None, None, None).await.unwrap();
    s.revoke_invite(&invite.code, None).await.unwrap();

    let rust_usable = rust_says_usable(&s, &invite.code).await;
    let sql_usable = sql_says_usable(&s, &invite.code, user.id).await;
    assert_eq!(rust_usable, sql_usable, "diverged on a revoked invite");
    assert!(!rust_usable, "a revoked invite must not be usable");
}
