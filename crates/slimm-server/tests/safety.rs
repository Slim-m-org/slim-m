// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the device list, blocking, and report intake.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request};

/// Counts open reports through the real paged query the moderation queue
/// route uses, with nothing hidden: these tests exercise report filing, not
/// per-channel visibility, so every channel is moderatable.
async fn open_report_count(store: &Store) -> i64 {
    store.list_open_reports(None, &[], 100).await.unwrap().len() as i64
}

#[tokio::test]
async fn devices_list_and_sign_out_only_your_own() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();

    // Alice signs in on two devices; bob on one.
    let laptop = store.open_session(alice.id, "laptop").await.unwrap();
    let phone = store.open_session(alice.id, "phone").await.unwrap();
    let bob_device = store.open_session(bob.id, "bob-laptop").await.unwrap();
    let app = app(store.clone());

    let devices = json_body(
        app.clone()
            .oneshot(request("GET", "/devices", Some(&laptop.access_token), None))
            .await
            .unwrap(),
    )
    .await;
    let devices = devices.as_array().unwrap();
    assert_eq!(devices.len(), 2, "only alice's own devices");
    let current: Vec<_> = devices
        .iter()
        .filter(|d| d["is_current"].as_bool().unwrap())
        .collect();
    assert_eq!(current.len(), 1, "exactly one device is flagged as current");

    // Alice signs the phone out; its token dies at once.
    let removed = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/devices/{}", phone.device_id),
            Some(&laptop.access_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(removed.status(), StatusCode::NO_CONTENT);
    assert!(
        store
            .authenticate(&phone.access_token)
            .await
            .unwrap()
            .is_none()
    );

    // Alice cannot touch bob's device, and it reads as missing rather than
    // forbidden, so she cannot even confirm it exists.
    let other = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/devices/{}", bob_device.device_id),
            Some(&laptop.access_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(other.status(), StatusCode::NOT_FOUND);
    assert!(
        store
            .authenticate(&bob_device.access_token)
            .await
            .unwrap()
            .is_some(),
        "bob's session is untouched"
    );
}

/// A device opened with a client kind and version reports both on the list;
/// one opened the plain way (every existing test fixture, and any session
/// from before migration 0076) reports neither rather than failing.
#[tokio::test]
async fn devices_list_reports_client_kind_and_version_when_known() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();

    let desktop = store
        .open_session_as(
            alice.id,
            "Linux (fedora)",
            Some("desktop"),
            Some("0.83.0"),
            None,
        )
        .await
        .unwrap();
    let plain = store.open_session(alice.id, "an old client").await.unwrap();
    let app = app(store.clone());

    let devices = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/devices",
                Some(&desktop.access_token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let devices = devices.as_array().unwrap();
    let known = devices
        .iter()
        .find(|d| d["id"] == desktop.device_id.to_string())
        .unwrap();
    assert_eq!(known["client_kind"], "desktop");
    assert_eq!(known["client_version"], "0.83.0");

    let unknown = devices
        .iter()
        .find(|d| d["id"] == plain.device_id.to_string())
        .unwrap();
    assert!(unknown["client_kind"].is_null());
    assert!(unknown["client_version"].is_null());
}

/// Every sign-in mints a fresh device row and nothing ever deletes one on an
/// ordinary logout (only the explicit "remove this device" action does), so
/// the list must filter live sessions out from under it rather than showing
/// every device an account has ever signed into.
///
/// Logout (`Store::revoke_session`) is used here rather than
/// `Store::remove_device`, on purpose: that path leaves the device row
/// sitting in the table untouched (only its sessions, tokens and tickets
/// die), so this is the case a naive "select every device row" query cannot
/// tell from one still in active use.
#[tokio::test]
async fn devices_list_hides_a_signed_out_device() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();

    let laptop = store.open_session(alice.id, "laptop").await.unwrap();
    let phone = store.open_session(alice.id, "phone").await.unwrap();
    let app = app(store.clone());

    let before = json_body(
        app.clone()
            .oneshot(request("GET", "/devices", Some(&laptop.access_token), None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(before.as_array().unwrap().len(), 2);

    // An ordinary logout, not removal: the phone's device row stays.
    store.revoke_session(phone.session_id).await.unwrap();

    let after = json_body(
        app.clone()
            .oneshot(request("GET", "/devices", Some(&laptop.access_token), None))
            .await
            .unwrap(),
    )
    .await;
    let after = after.as_array().unwrap();
    assert_eq!(
        after.len(),
        1,
        "a signed-out device must drop out of the list, not just its own token stop working"
    );
    assert_eq!(after[0]["name"], "laptop");
}

#[tokio::test]
async fn blocking_is_private_idempotent_and_one_directional() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let alice_session = store.open_session(alice.id, "d").await.unwrap();
    let app = app(store.clone());

    let block = |token: String, target: String| {
        request("POST", &format!("/blocks/{target}"), Some(&token), None)
    };

    let first = app
        .clone()
        .oneshot(block(
            alice_session.access_token.clone(),
            bob.id.to_string(),
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::NO_CONTENT);
    // Blocking twice is not an error; the user just wants them blocked.
    let again = app
        .clone()
        .oneshot(block(
            alice_session.access_token.clone(),
            bob.id.to_string(),
        ))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::NO_CONTENT);

    let blocks = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                "/blocks",
                Some(&alice_session.access_token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(blocks.as_array().unwrap().len(), 1);

    // One-directional: bob has not blocked alice just because she blocked him.
    assert!(store.has_blocked(alice.id, bob.id).await.unwrap());
    assert!(!store.has_blocked(bob.id, alice.id).await.unwrap());

    // Blocking yourself is refused rather than silently stored.
    let self_block = app
        .clone()
        .oneshot(block(
            alice_session.access_token.clone(),
            alice.id.to_string(),
        ))
        .await
        .unwrap();
    assert_eq!(self_block.status(), StatusCode::BAD_REQUEST);

    let unblocked = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/blocks/{}", bob.id),
            Some(&alice_session.access_token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(unblocked.status(), StatusCode::NO_CONTENT);
    assert!(!store.has_blocked(alice.id, bob.id).await.unwrap());
}

#[tokio::test]
async fn reporting_a_message_keeps_a_snapshot_and_resists_flooding() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let reporter = store.open_session(alice.id, "d").await.unwrap();

    let message = store
        .send_message(NewMessage::plain(
            channel.id,
            bob.id,
            MessageId::generate(),
            "something awful",
        ))
        .await
        .unwrap()
        .message;
    let app = app(store.clone());

    let filed = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&reporter.access_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message.id.to_string(),
                "reason": "harassment"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(filed.status(), StatusCode::OK);
    assert_eq!(open_report_count(&store).await, 1);

    // The same reporter cannot pile up reports on the same subject.
    let duplicate = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&reporter.access_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message.id.to_string(),
                "reason": "harassment again"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(duplicate.status(), StatusCode::CONFLICT);
    assert_eq!(open_report_count(&store).await, 1);

    // The snapshot survives the author deleting or editing the content, which is
    // the whole reason it is stored.
    store
        .edit_message(message.id, "innocuous now", alice.id)
        .await
        .unwrap();
    assert_eq!(
        open_report_count(&store).await,
        1,
        "the report still stands"
    );

    // A reason is required; an empty one is a bad request, not an empty report.
    let no_reason = app
        .clone()
        .oneshot(request(
            "POST",
            "/reports",
            Some(&reporter.access_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message.id.to_string(),
                "reason": "   "
            })),
        ))
        .await
        .unwrap();
    assert_eq!(no_reason.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_message_you_cannot_see_cannot_be_reported() {
    let (store, _guard) = support::new_store("slimm-safety-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await.unwrap();
    let bob = store.create_account("bob", "Bob", &hash).await.unwrap();
    let hidden = store.create_channel("hidden", "text").await.unwrap();
    let message = store
        .send_message(NewMessage::plain(
            hidden.id,
            bob.id,
            MessageId::generate(),
            "private",
        ))
        .await
        .unwrap()
        .message;

    // Alice is denied view of that channel.
    store
        .set_member_overwrite(
            hidden.id,
            alice.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let session = store.open_session(alice.id, "d").await.unwrap();
    let app = app(store.clone());

    // Reported as not found, so the endpoint cannot be used to confirm that a
    // message exists in a channel she cannot read.
    let response = app
        .oneshot(request(
            "POST",
            "/reports",
            Some(&session.access_token),
            Some(json!({
                "subject_kind": "message",
                "subject_id": message.id.to_string(),
                "reason": "probing"
            })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_eq!(open_report_count(&store).await, 0);
}
