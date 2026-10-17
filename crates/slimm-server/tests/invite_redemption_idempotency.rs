// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Redemption is idempotent per (code, user): a retry after a lost response
//! spends no second use and reports the success it already achieved, and a
//! code spent at registration cannot be redeemed a second time by the same
//! account. Its own file because `invites.rs` is already at the line budget.
//! See SRV5 and `Store::redeem_invite`.

use slimm_server::store::Store;

mod support;

/// The current use count of `code`.
async fn uses(store: &Store, code: &str) -> i64 {
    store
        .list_invites(None)
        .await
        .unwrap()
        .into_iter()
        .find(|invite| invite.code == code)
        .expect("invite exists")
        .uses
}

#[tokio::test]
async fn a_retry_by_the_same_user_spends_no_second_use() {
    let (store, _pool, _guard) = support::new_store_with_pool("slimm-invite-idempotency").await;
    let creator = store.create_account("creator", "C", "h").await.unwrap();
    store.bootstrap_deployment(creator.id).await.unwrap();
    let alice = store.create_account("alice", "A", "h").await.unwrap();
    let bob = store.create_account("bob", "B", "h").await.unwrap();

    let invite = store
        .create_invite(creator.id, None, Some(2), None)
        .await
        .unwrap();

    let fresh = store.redeem_invite(&invite.code, alice.id).await.unwrap();
    assert!(fresh, "a first redemption must report itself as fresh");
    assert_eq!(uses(&store, &invite.code).await, 1);

    // Alice retries the same redemption: a no-op, not a second use.
    let retried = store.redeem_invite(&invite.code, alice.id).await.unwrap();
    assert!(
        !retried,
        "a retry must not report itself as fresh, or MemberJoined fires twice"
    );
    assert_eq!(
        uses(&store, &invite.code).await,
        1,
        "a retry must not burn a second use"
    );

    // The slot Alice's retry did not take is still there for Bob.
    let bob_fresh = store.redeem_invite(&invite.code, bob.id).await.unwrap();
    assert!(bob_fresh);
    assert_eq!(uses(&store, &invite.code).await, 2);
    assert!(!store.invite_is_usable(&invite.code).await.unwrap());
}

#[tokio::test]
async fn a_retry_on_a_single_use_invite_reports_success_not_failure() {
    let (store, _pool, _guard) = support::new_store_with_pool("slimm-invite-idempotency").await;
    let creator = store.create_account("creator", "C", "h").await.unwrap();
    store.bootstrap_deployment(creator.id).await.unwrap();
    let alice = store.create_account("alice", "A", "h").await.unwrap();

    let invite = store
        .create_invite(creator.id, None, Some(1), None)
        .await
        .unwrap();

    store.redeem_invite(&invite.code, alice.id).await.unwrap();
    // The invite is spent, but Alice's own retry must still read as success, not the "unusable" a new user gets.
    let retry = store.redeem_invite(&invite.code, alice.id).await;
    assert!(
        retry.is_ok(),
        "a retry of a succeeded redemption must not report failure: {retry:?}"
    );
    assert_eq!(uses(&store, &invite.code).await, 1);
}

#[tokio::test]
async fn a_code_used_at_registration_cannot_be_redeemed_again() {
    let (store, _pool, _guard) = support::new_store_with_pool("slimm-invite-idempotency").await;
    let creator = store.create_account("creator", "C", "h").await.unwrap();
    store.bootstrap_deployment(creator.id).await.unwrap();

    let invite = store
        .create_invite(creator.id, None, Some(2), None)
        .await
        .unwrap();

    // Joining with the code spends one use and records the redemption.
    let joiner = store
        .register_account("joiner", "J", "h", Some(&invite.code))
        .await
        .unwrap();
    assert_eq!(uses(&store, &invite.code).await, 1);

    // The same account redeeming that code again is a no-op, not a second use.
    store.redeem_invite(&invite.code, joiner.id).await.unwrap();
    assert_eq!(
        uses(&store, &invite.code).await,
        1,
        "a code spent at registration must not be re-spent by the same account"
    );
}

#[tokio::test]
async fn deleting_an_account_purges_its_invite_redemptions() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-invite-idempotency").await;
    let creator = store.create_account("creator", "C", "h").await.unwrap();
    store.bootstrap_deployment(creator.id).await.unwrap();
    let alice = store.create_account("alice", "A", "h").await.unwrap();

    let invite = store
        .create_invite(creator.id, None, Some(2), None)
        .await
        .unwrap();
    store.redeem_invite(&invite.code, alice.id).await.unwrap();

    let before: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM invite_redemptions WHERE user_id = ?")
            .bind(alice.id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(before, 1, "the redemption was recorded");

    store.delete_account(alice.id).await.unwrap();

    let after: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM invite_redemptions WHERE user_id = ?")
            .bind(alice.id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        after, 0,
        "deleting the account must purge its redemption, not leave it outliving the anonymized account"
    );
}
