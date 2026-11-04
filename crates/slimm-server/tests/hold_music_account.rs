// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hold music is an account choice: unset until made, then the same wherever
//! it is read.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;

mod support;

async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-hold-music");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

#[tokio::test]
async fn an_account_that_never_chose_reads_none() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();

    assert_eq!(s.hold_music(alice.id).await.unwrap(), Some(None));
}

#[tokio::test]
async fn a_choice_is_kept_and_can_be_changed() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();

    assert!(s.set_hold_music(alice.id, true).await.unwrap());
    assert_eq!(s.hold_music(alice.id).await.unwrap(), Some(Some(true)));
    assert!(s.set_hold_music(alice.id, false).await.unwrap());
    assert_eq!(s.hold_music(alice.id).await.unwrap(), Some(Some(false)));
    assert_eq!(s.hold_music(bob.id).await.unwrap(), Some(None));
}
