// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A refused ring tells nobody anything: no `call.ringing` frame, no push.
//!
//! The ring route only had happy-path coverage, so every one of its gates
//! (pair membership, DM shape, personal space, CONNECT, VIEW_CHANNEL) could
//! have been removed with the suite staying green.

use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;
use slimm_server::push::PushSender;
use slimm_server::store::Store;
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

use crate::call_signals::register_device;
use crate::harness::{
    MockRelay, SHORT_DEBOUNCE_MS, WAIT_TIMEOUT, app_with_voice, push_config, request,
    spawn_mock_relay, wait_until,
};
use crate::missed_call::{open_dm, voice};

struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    owner: UserId,
    mock: MockRelay,
    durable: Receiver<Event>,
    ephemeral: Receiver<Event>,
    _guard: crate::support::TestDbGuard,
}

struct Member {
    id: UserId,
    token: String,
}

async fn world() -> World {
    let (store, pool, guard) = crate::support::new_store_with_pool("slimm-ring-refusals").await;
    let (mock, relay_url) = spawn_mock_relay().await;
    let push = PushSender::with_debounce_window_ms(&push_config(&relay_url), SHORT_DEBOUNCE_MS)
        .expect("relay config is valid");
    let hub = Hub::new();
    let durable = hub.subscribe();
    let ephemeral = hub.subscribe_ephemeral();
    let app = app_with_voice(store.clone(), push, voice(), hub);
    let owner = store.create_account("owner", "owner", "x").await.unwrap();
    store.bootstrap_deployment(owner.id).await.unwrap();
    World {
        app,
        store,
        pool,
        owner: owner.id,
        mock,
        durable,
        ephemeral,
        _guard: guard,
    }
}

impl World {
    /// A member with a session and a push device named after them.
    async fn member(&self, name: &str) -> Member {
        let account = self.store.create_account(name, name, "x").await.unwrap();
        let tokens = self.store.open_session(account.id, "cli").await.unwrap();
        let _secret = register_device(
            &self.app,
            &tokens.access_token,
            "android",
            &format!("{name}-device"),
            None,
        )
        .await;
        Member {
            id: account.id,
            token: tokens.access_token,
        }
    }

    async fn ring(&self, channel_id: &str, who: &Member) -> StatusCode {
        self.app
            .clone()
            .oneshot(request(
                "POST",
                &format!("/channels/{channel_id}/voice/ring"),
                Some(&who.token),
                None,
            ))
            .await
            .unwrap()
            .status()
    }

    fn rang_on_the_wire(&mut self) -> bool {
        let mut rang = false;
        for rx in [&mut self.durable, &mut self.ephemeral] {
            while let Ok(event) = rx.try_recv() {
                rang |= matches!(event, Event::CallRinging { .. });
            }
        }
        rang
    }

    /// Outlasts the debounce window, so a push that was going to fire has.
    async fn settle(&self) {
        tokio::time::sleep(Duration::from_millis((SHORT_DEBOUNCE_MS * 3) as u64)).await;
    }

    async fn assert_silent(&mut self, what: &str) {
        self.settle().await;
        assert!(
            !self.rang_on_the_wire(),
            "{what}: call.ringing was published"
        );
        assert_eq!(self.mock.attempt_count(), 0, "{what}: a push went out");
    }
}

#[tokio::test]
async fn a_third_user_cannot_ring_someone_elses_dm() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let mallory = w.member("mallory").await;
    let channel = open_dm(&w.app, &alice.token, &bob.id.to_string()).await;

    assert_eq!(w.ring(&channel, &mallory).await, StatusCode::FORBIDDEN);
    w.assert_silent("a bystander's ring").await;

    // Control: the same harness does see a legitimate ring, so the silence above means something.
    assert_eq!(w.ring(&channel, &alice).await, StatusCode::OK);
    assert!(w.rang_on_the_wire());
    assert!(wait_until(|| w.mock.call_count() > 0, WAIT_TIMEOUT).await);
}

#[tokio::test]
async fn a_channel_that_is_not_a_dm_cannot_be_rung() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();

    assert_eq!(
        w.ring(&channel.id.to_string(), &alice).await,
        StatusCode::NOT_FOUND
    );
    w.assert_silent("a non-DM channel").await;
}

#[tokio::test]
async fn a_personal_space_has_nobody_to_ring() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let channel = open_dm(&w.app, &alice.token, &alice.id.to_string()).await;

    assert_eq!(w.ring(&channel, &alice).await, StatusCode::NOT_FOUND);
    w.assert_silent("a personal space").await;
}

#[tokio::test]
async fn a_caller_without_connect_cannot_ring() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let channel = open_dm(&w.app, &alice.token, &bob.id.to_string()).await;
    let until = chrono_free_now_ms() + 3_600_000;
    w.store
        .set_member_timeout(alice.id, until, None, w.owner)
        .await
        .unwrap();

    assert_eq!(w.ring(&channel, &alice).await, StatusCode::FORBIDDEN);
    w.assert_silent("a timed-out caller").await;
}

#[tokio::test]
async fn a_caller_who_blocked_the_callee_cannot_ring() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let channel = open_dm(&w.app, &alice.token, &bob.id.to_string()).await;
    let blocked = w
        .app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/blocks/{}", bob.id),
            Some(&alice.token),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(blocked.status(), StatusCode::NO_CONTENT);

    assert_eq!(w.ring(&channel, &alice).await, StatusCode::FORBIDDEN);
    w.assert_silent("a blocking caller").await;
}

#[tokio::test]
async fn a_caller_without_view_channel_cannot_ring() {
    let mut w = world().await;
    let alice = w.member("alice").await;
    let bob = w.member("bob").await;
    let channel = open_dm(&w.app, &alice.token, &bob.id.to_string()).await;
    // A pending member keeps no permission outside the rules channel.
    sqlx::query("INSERT INTO pending_members (user_id, since) VALUES (?, 0)")
        .bind(alice.id)
        .execute(&w.pool)
        .await
        .unwrap();

    assert_eq!(w.ring(&channel, &alice).await, StatusCode::FORBIDDEN);
    w.assert_silent("a caller who cannot view the channel")
        .await;
}

fn chrono_free_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
