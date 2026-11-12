// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Operator alerts pushed through the relay: who is pushed, the six-hour rate limit per kind,
//! the recovery notice, and a relay that stops answering.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use slimm_server::admin_alerts::{AlertKind, Notifier};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use tower::ServiceExt;

use crate::push_endpoints::call_signals::register_device;
use crate::push_endpoints::harness::{
    SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app, json_body, push_config, register_user, request,
    seeded_store, spawn_mock_relay, wait_until,
};

struct World {
    notifier: Notifier,
    push: PushSender,
    mock: crate::push_endpoints::harness::MockRelay,
    admin_secret: crypto_box::SecretKey,
    app: axum::Router,
    admin_token: String,
    _guard: crate::support::TestDbGuard,
}

async fn world() -> World {
    let (store, _channel, guard) = seeded_store().await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let app = app(store.clone(), push.clone());
    let (admin_token, admin_id) = register_user(&store, "root").await;
    let ops = store
        .create_role(
            "ops",
            slimm_server::permissions::Permissions::MANAGE_SERVER,
            false,
        )
        .await
        .unwrap();
    let admin_id = slimm_server::ids::UserId(uuid::Uuid::parse_str(&admin_id).unwrap());
    store.assign_role(admin_id, ops).await.unwrap();
    let (member_token, _) = register_user(&store, "nia").await;
    let admin_secret = register_device(&app, &admin_token, "ios", "root-apns", None).await;
    register_device(&app, &member_token, "ios", "nia-apns", None).await;
    World {
        notifier: Notifier::new(store.clone(), Hub::new(), push.clone()),
        push,
        mock,
        admin_secret,
        app,
        admin_token,
        _guard: guard,
    }
}

fn unseal(world: &World, message: &Value) -> Value {
    let sealed = BASE64.decode(message["payload"].as_str().unwrap()).unwrap();
    serde_json::from_slice(&world.admin_secret.unseal(&sealed).expect("unseal")).unwrap()
}

#[tokio::test]
async fn an_alert_reaches_the_admin_and_not_the_member() {
    let world = world().await;

    world
        .notifier
        .raise(AlertKind::DiskLow, "", "Only 90 MB are free.")
        .await;

    assert!(wait_until(|| world.mock.all_messages().len() == 1, WAIT_TIMEOUT).await);
    let messages = world.mock.all_messages();
    assert_eq!(messages[0]["token"], "root-apns");
    assert_eq!(messages[0]["kind"], "admin_alert");
    let envelope = unseal(&world, &messages[0]);
    assert_eq!(envelope["event"], "admin_alert");
    assert_eq!(envelope["title"], "Disk space is low");
    assert_eq!(envelope["body"], "Only 90 MB are free.");
}

#[tokio::test]
async fn a_relay_without_the_admin_alert_kind_still_delivers_it_as_security() {
    let world = world().await;
    world.mock.refuse_kind("admin_alert");

    world
        .notifier
        .raise(AlertKind::DiskLow, "", "Only 90 MB are free.")
        .await;
    assert!(wait_until(|| world.mock.all_messages().len() == 2, WAIT_TIMEOUT).await);
    let kinds: Vec<_> = world
        .mock
        .all_messages()
        .iter()
        .map(|m| m["kind"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        kinds,
        ["admin_alert", "security"],
        "refused, then sent as the older kind"
    );

    world
        .notifier
        .raise(AlertKind::Backup, "", "The backup failed.")
        .await;
    assert!(wait_until(|| world.mock.all_messages().len() == 3, WAIT_TIMEOUT).await);
    assert_eq!(
        world.mock.all_messages()[2]["kind"],
        "security",
        "after a refusal the older kind goes first"
    );
}

/// How long a test waits to be sure the server sent nothing more.
const QUIET: std::time::Duration = std::time::Duration::from_millis(400);

fn kinds(world: &World) -> Vec<String> {
    let sent = world.mock.all_messages();
    sent.iter()
        .map(|m| m["kind"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn a_relay_that_cannot_deliver_right_now_does_not_downgrade_the_kind() {
    for status in ["retry", "rejected"] {
        let world = world().await;
        world.mock.set_status("root-apns", status);

        world.notifier.raise(AlertKind::DiskLow, "", "low").await;
        assert!(wait_until(|| world.mock.all_messages().len() == 1, WAIT_TIMEOUT).await);
        assert!(
            !wait_until(|| world.mock.all_messages().len() > 1, QUIET).await,
            "{status}: the alert was sent again under another kind"
        );
        world.notifier.raise(AlertKind::Backup, "", "failed").await;
        assert!(wait_until(|| world.mock.all_messages().len() == 2, WAIT_TIMEOUT).await);

        assert_eq!(kinds(&world), ["admin_alert", "admin_alert"], "{status}");
    }
}

#[tokio::test]
async fn an_older_kind_the_relay_also_fails_does_not_prove_it_predates_the_new_one() {
    let world = world().await;
    world.mock.refuse_kind("admin_alert");
    world.mock.set_status("root-apns", "error");

    world.notifier.raise(AlertKind::DiskLow, "", "low").await;
    assert!(wait_until(|| world.mock.all_messages().len() == 2, WAIT_TIMEOUT).await);
    world.notifier.raise(AlertKind::Backup, "", "failed").await;
    assert!(wait_until(|| world.mock.all_messages().len() == 4, WAIT_TIMEOUT).await);

    assert_eq!(
        kinds(&world),
        ["admin_alert", "security", "admin_alert", "security"],
        "an outage that fails both kinds must not switch the server to the older one"
    );
}

#[tokio::test]
async fn a_muted_admin_is_not_pushed() {
    let world = world().await;
    let muted = world
        .app
        .clone()
        .oneshot(request(
            "PUT",
            "/space/alerts/mute",
            Some(&world.admin_token),
            Some(json!({ "muted": true })),
        ))
        .await
        .unwrap();
    assert_eq!(muted.status(), axum::http::StatusCode::OK);

    world.notifier.raise(AlertKind::DiskLow, "", "low").await;

    assert!(
        !wait_until(
            || world.mock.call_count() > 0,
            std::time::Duration::from_millis(400)
        )
        .await
    );
}

#[tokio::test]
async fn a_second_alert_of_the_same_kind_inside_six_hours_is_not_pushed() {
    let world = world().await;
    world
        .notifier
        .raise(AlertKind::ModuleBreaker, "tally", "tally was turned off.")
        .await;
    assert!(wait_until(|| world.mock.all_messages().len() == 1, WAIT_TIMEOUT).await);

    world
        .notifier
        .raise(AlertKind::ModuleBreaker, "quotes", "quotes was turned off.")
        .await;

    assert!(
        !wait_until(
            || world.mock.all_messages().len() > 1,
            std::time::Duration::from_millis(400)
        )
        .await
    );
    let listed = list(&world).await;
    assert_eq!(
        listed["alerts"].as_array().unwrap().len(),
        2,
        "both are still listed: {listed}"
    );
}

#[tokio::test]
async fn recovery_pushes_a_notice_when_the_opening_was_pushed() {
    let world = world().await;
    world
        .notifier
        .raise(AlertKind::Backup, "", "The nightly backup failed.")
        .await;
    assert!(wait_until(|| world.mock.all_messages().len() == 1, WAIT_TIMEOUT).await);

    world.notifier.resolve(AlertKind::Backup, "").await;

    assert!(wait_until(|| world.mock.all_messages().len() == 2, WAIT_TIMEOUT).await);
    let envelope = unseal(&world, &world.mock.all_messages()[1]);
    assert_eq!(envelope["title"], "Recovered: Backup needs attention");
}

#[tokio::test]
async fn recovery_stays_quiet_when_the_opening_was_rate_limited() {
    let world = world().await;
    world.notifier.raise(AlertKind::Backup, "", "failed").await;
    assert!(wait_until(|| world.mock.all_messages().len() == 1, WAIT_TIMEOUT).await);
    world.notifier.resolve(AlertKind::Backup, "").await;
    assert!(wait_until(|| world.mock.all_messages().len() == 2, WAIT_TIMEOUT).await);

    world
        .notifier
        .raise(AlertKind::Backup, "", "failed again")
        .await;
    world.notifier.resolve(AlertKind::Backup, "").await;

    assert!(
        !wait_until(
            || world.mock.all_messages().len() > 2,
            std::time::Duration::from_millis(400)
        )
        .await
    );
}

#[tokio::test]
async fn failed_sends_to_the_relay_count_until_one_gets_through() {
    let world = world().await;
    world.mock.fail_next_calls(3);

    for kind in [AlertKind::DiskLow, AlertKind::Backup, AlertKind::Livekit] {
        world.notifier.raise(kind, "", "down").await;
    }
    assert!(
        wait_until(
            || world.push.relay_consecutive_failures() == 3,
            WAIT_TIMEOUT
        )
        .await
    );

    world.notifier.raise(AlertKind::PushRelay, "", "down").await;
    assert!(
        wait_until(
            || world.push.relay_consecutive_failures() == 0,
            WAIT_TIMEOUT
        )
        .await
    );
}

async fn list(world: &World) -> Value {
    let response = world
        .app
        .clone()
        .oneshot(request(
            "GET",
            "/space/alerts",
            Some(&world.admin_token),
            None,
        ))
        .await
        .unwrap();
    json_body(response).await
}
