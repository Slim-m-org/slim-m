// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for push registration persistence: device-scoping,
//! target listing, and clearing a dead registration.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::{PushError, PushRegistration, Store};

use crate::support;
async fn store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-push-store-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

const KEY_A: [u8; 32] = [0xAA; 32];
const KEY_B: [u8; 32] = [0xBB; 32];

/// Bob presenting alice's device id (spoofed into the store call directly,
/// since the HTTP layer never even accepts a body-supplied device id) is
/// refused: the (device_id, user_id) pair does not match.
#[tokio::test]
async fn register_is_scoped_to_the_callers_own_device() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let alice_session = s.open_session(alice.id, "phone").await.unwrap();

    let forged = s
        .register_push(
            bob.id,
            alice_session.device_id,
            PushRegistration {
                platform: "ios",
                push_token: "bob-tries-alices-device",
                voip_push_token: None,
                push_public_key: &KEY_A,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await;
    assert!(matches!(forged, Err(PushError::NotFound)));

    // Bob's attempt wrote nothing: alice's device has no registration yet.
    assert!(s.push_targets(&[alice.id]).await.unwrap().is_empty());

    // The legitimate owner succeeds.
    s.register_push(
        alice.id,
        alice_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "alices-real-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].push_token, "alices-real-token");
    assert_eq!(targets[0].device_id, alice_session.device_id);

    // Bob still cannot write it after the fact either.
    let forged_again = s
        .register_push(
            bob.id,
            alice_session.device_id,
            PushRegistration {
                platform: "android",
                push_token: "bob-overwrite-attempt",
                voip_push_token: None,
                push_public_key: &KEY_B,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await;
    assert!(matches!(forged_again, Err(PushError::NotFound)));
    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(
        targets[0].push_token, "alices-real-token",
        "the forged write never touched alice's registration"
    );
}

#[tokio::test]
async fn deregister_is_scoped_to_the_callers_own_device() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let alice_session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        alice_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "alices-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    // Bob cannot deregister alice's device.
    let forged = s.deregister_push(bob.id, alice_session.device_id).await;
    assert!(matches!(forged, Err(PushError::NotFound)));
    assert_eq!(s.push_targets(&[alice.id]).await.unwrap().len(), 1);

    // Alice can deregister her own.
    s.deregister_push(alice.id, alice_session.device_id)
        .await
        .unwrap();
    assert!(s.push_targets(&[alice.id]).await.unwrap().is_empty());
}

#[tokio::test]
async fn report_lifecycle_is_scoped_to_the_callers_own_device() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let alice_session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        alice_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "alices-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    let forged = s
        .report_lifecycle(bob.id, alice_session.device_id, "foreground")
        .await;
    assert!(matches!(forged, Err(PushError::NotFound)));
    assert_eq!(
        s.push_targets(&[alice.id]).await.unwrap()[0].lifecycle_state,
        None
    );

    s.report_lifecycle(alice.id, alice_session.device_id, "foreground")
        .await
        .unwrap();
    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(targets[0].lifecycle_state.as_deref(), Some("foreground"));
    assert!(targets[0].lifecycle_reported_at.is_some());
}

#[tokio::test]
async fn a_device_that_never_registered_is_never_a_push_target() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    s.open_session(alice.id, "phone").await.unwrap();
    let bob_session = s.open_session(bob.id, "phone").await.unwrap();
    s.register_push(
        bob.id,
        bob_session.device_id,
        PushRegistration {
            platform: "android",
            push_token: "bobs-token",
            voip_push_token: None,
            push_public_key: &KEY_B,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    // Alice has a live device but never registered a push key; she must be
    // skipped rather than somehow appear as a plaintext-capable target.
    let targets = s.push_targets(&[alice.id, bob.id]).await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].user_id, bob.id);
}

#[tokio::test]
async fn clearing_a_dead_token_never_clobbers_a_fresher_registration() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "token-v1",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    // The relay eventually reports token-v1 unregistered and this clears it.
    s.clear_push_registration(alice.id, session.device_id, "token-v1")
        .await
        .unwrap();
    assert!(s.push_targets(&[alice.id]).await.unwrap().is_empty());

    // The device re-registers with a fresh token...
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "token-v2",
            voip_push_token: None,
            push_public_key: &KEY_B,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    // ...and a stale report for the old token arriving late must not wipe it:
    // push_token_ref no longer matches token-v1, so this is a no-op.
    s.clear_push_registration(alice.id, session.device_id, "token-v1")
        .await
        .unwrap();
    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(
        targets.len(),
        1,
        "the fresh registration survives a stale clear"
    );
    assert_eq!(targets[0].push_token, "token-v2");
}

#[tokio::test]
async fn clear_push_registration_is_scoped_to_the_owning_device_not_the_bare_token() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let alice_session = s.open_session(alice.id, "phone").await.unwrap();
    let bob_session = s.open_session(bob.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        alice_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "alices-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    // A clear resolved against bob's own device and user id but naming alice's
    // token must not reach her row: a bare token identifies no owner at all.
    s.clear_push_registration(bob.id, bob_session.device_id, "alices-token")
        .await
        .unwrap();

    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(
        targets.len(),
        1,
        "a differently-owned device's clear call never touches alice's registration"
    );
    assert_eq!(targets[0].push_token, "alices-token");
}

#[tokio::test]
async fn a_logged_out_device_receives_nothing() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let session = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "alices-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    assert_eq!(s.push_targets(&[alice.id]).await.unwrap().len(), 1);

    // Logging out revokes the session; the device must stop being a push
    // target immediately, not merely once some other filter happens to run.
    s.revoke_session(session.session_id).await.unwrap();
    assert!(
        s.push_targets(&[alice.id]).await.unwrap().is_empty(),
        "a signed-out device must never receive push"
    );
}

/// Each login mints a brand new device row, so without the session-liveness
/// filter and the token hand-off, one physical phone that logged out and back
/// in with the same provider token would leave two live-looking push targets.
#[tokio::test]
async fn repeated_logins_do_not_produce_duplicate_targets_for_one_physical_device() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();

    // Alice logs in on her phone, registers it for push, then logs out.
    let first_login = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        first_login.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "phones-real-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    s.revoke_session(first_login.session_id).await.unwrap();

    // She logs back in on the same physical phone and registers the same
    // underlying provider token again.
    let second_login = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        second_login.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "phones-real-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(
        targets.len(),
        1,
        "one physical device must never appear as two push targets after repeated logins"
    );
    assert_eq!(targets[0].device_id, second_login.device_id);
}

/// If a physical device's token is re-registered from a brand new login that
/// never explicitly logged the previous one out (a session simply left live),
/// the fresh registration must still be the only thing that token can wake:
/// `register_push` itself hands the token off, rather than relying solely on
/// the eventual logout to clean up the old row.
#[tokio::test]
async fn registering_a_token_on_a_new_login_reclaims_it_even_without_logging_out() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let first_login = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        first_login.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "phones-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    let second_login = s.open_session(alice.id, "phone").await.unwrap();
    s.register_push(
        alice.id,
        second_login.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "phones-token",
            voip_push_token: None,
            push_public_key: &KEY_B,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    let targets = s.push_targets(&[alice.id]).await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].device_id, second_login.device_id);
}

/// A provider push token is a handle to one physical device, not a stable
/// identity: a reinstall on a shared handset can legitimately hand it to a
/// different account. Whoever registers it now is its owner, and the previous
/// owner must stop receiving push to it.
#[tokio::test]
async fn a_token_reassigned_to_a_different_account_stops_reaching_the_old_one() {
    let (s, _guard) = store().await;
    let alice = s.create_user("alice", "Alice").await.unwrap();
    let bob = s.create_user("bob", "Bob").await.unwrap();
    let alice_session = s.open_session(alice.id, "shared-phone").await.unwrap();
    s.register_push(
        alice.id,
        alice_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "shared-token",
            voip_push_token: None,
            push_public_key: &KEY_A,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();
    assert_eq!(s.push_targets(&[alice.id]).await.unwrap().len(), 1);

    let bob_session = s.open_session(bob.id, "shared-phone").await.unwrap();
    s.register_push(
        bob.id,
        bob_session.device_id,
        PushRegistration {
            platform: "ios",
            push_token: "shared-token",
            voip_push_token: None,
            push_public_key: &KEY_B,
            include_content: Some(false),
            include_content_chosen: true,
        },
    )
    .await
    .unwrap();

    assert!(
        s.push_targets(&[alice.id]).await.unwrap().is_empty(),
        "alice's stale registration for a reassigned token must be gone"
    );
    let bob_targets = s.push_targets(&[bob.id]).await.unwrap();
    assert_eq!(bob_targets.len(), 1);
    assert_eq!(bob_targets[0].push_token, "shared-token");
}
