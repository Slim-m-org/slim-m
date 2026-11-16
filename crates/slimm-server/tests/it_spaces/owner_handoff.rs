// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ownership passing on: the heir holds every permission at once, a timeout included, and every
//! client is told, whether the owner deleted their account or a read found the stored owner gone.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::sync::broadcast::Receiver;

use crate::support;
use support::app::{Account, call_as, general_channel_id, register_account};

const PASSWORD: &str = "hunter2hunter2";

/// alice owns the Space and can sign her deletion; bob is an administrator who joined after her.
struct World {
    app: Router,
    hub: Hub,
    store: Store,
    pool: sqlx::SqlitePool,
    alice: Account,
    bob: Account,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let hub = Hub::new();
    let app = support::app::builder(store.clone())
        .hub(hub.clone())
        .router();
    let auth = Auth::new(2).unwrap();
    let hash = auth.hash_password(PASSWORD.to_owned()).await.unwrap();
    let alice = store.create_account("alice", "Alice", &hash).await;
    let alice = alice.unwrap().id;
    store.bootstrap_deployment(alice).await.unwrap();
    let token = store.open_session(alice, "cli").await.unwrap().access_token;
    let alice = Account { id: alice, token };
    let bob = register_account(&store, "bob").await;
    let roles = store.list_roles().await.unwrap();
    let admin = roles.iter().find(|r| r.name == "admin").unwrap().id;
    store.assign_role(bob.id, admin).await.unwrap();
    World {
        app,
        hub,
        store,
        pool,
        alice,
        bob,
        _guard: guard,
    }
}

async fn ok(app: &Router, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let (status, body) = call_as(app, method, uri, token, body).await;
    assert!(status.is_success(), "{method} {uri}: {status} {body}");
    body
}

/// What the hub said about `heir`: a lifted timeout, a changed profile, a new owner.
#[derive(Debug, Default, PartialEq)]
struct Told {
    timeout_lifted: bool,
    profile: bool,
    owner: bool,
}

fn told(rx: &mut Receiver<Event>, heir: UserId) -> Told {
    let mut told = Told::default();
    while let Ok(event) = rx.try_recv() {
        match event.into_inner() {
            Event::MemberTimeoutChanged { user_id, until } if user_id == heir => {
                told.timeout_lifted |= until.is_none();
            }
            Event::ProfileChanged(user_id) => told.profile |= user_id == heir,
            Event::OwnerChanged(user_id) => told.owner |= user_id == heir,
            _ => {}
        }
    }
    told
}

impl World {
    async fn delete_alice(&self) {
        let body = json!({ "password": PASSWORD });
        let token = &self.alice.token;
        let (status, body) = call_as(&self.app, "DELETE", "/account", token, Some(body)).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    }
}

#[tokio::test]
async fn a_timed_out_administrator_handed_ownership_holds_every_permission() {
    let w = world("slimm-owner-handoff-timeout").await;
    let timeout = json!({ "duration_seconds": 3600 });
    let uri = format!("/members/{}/timeout", w.bob.id);
    ok(&w.app, &w.alice.token, "PUT", &uri, Some(timeout)).await;

    let mut rx = w.hub.subscribe();
    w.delete_alice().await;
    let expected = Told {
        timeout_lifted: true,
        profile: true,
        owner: true,
    };
    assert_eq!(told(&mut rx, w.bob.id), expected);

    assert_eq!(w.store.space_owner().await.unwrap(), Some(w.bob.id));
    assert_eq!(
        w.store.base_permissions(w.bob.id).await.unwrap(),
        Permissions::ALL
    );
    let general = general_channel_id(&w.store).await;
    let message = json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "mine now" });
    let uri = format!("/channels/{general}/messages");
    ok(&w.app, &w.bob.token, "POST", &uri, Some(message)).await;
    let me = ok(&w.app, &w.bob.token, "GET", "/me", None).await;
    assert_eq!(me["is_owner"], true, "{me}");
    assert_eq!(me["timed_out_until"], Value::Null, "{me}");
}

#[tokio::test]
async fn deleting_the_owner_tells_every_client_who_the_heir_is() {
    let w = world("slimm-owner-handoff-deleted").await;
    let carol = register_account(&w.store, "carol").await;
    let deleted = w.store.delete_account(carol.id).await.unwrap();
    assert_eq!(deleted.handoff, None, "only the owner leaving hands on");

    let mut rx = w.hub.subscribe();
    w.delete_alice().await;
    let expected = Told {
        timeout_lifted: false,
        profile: true,
        owner: true,
    };
    assert_eq!(told(&mut rx, w.bob.id), expected);
}

/// Nothing in the API removes the owner, so the removal is written by hand.
#[tokio::test]
async fn a_read_that_finds_the_owner_gone_hands_on_and_says_so_once() {
    let w = world("slimm-owner-handoff-lazy").await;
    sqlx::query("INSERT INTO space_removals (user_id, removed_by, removed_at) VALUES (?, ?, 0)")
        .bind(w.alice.id)
        .bind(w.alice.id)
        .execute(&w.pool)
        .await
        .unwrap();
    let mut rx = w.hub.subscribe();

    let me = ok(&w.app, &w.bob.token, "GET", "/me", None).await;
    assert_eq!(me["is_owner"], true, "{me}");
    let expected = Told {
        timeout_lifted: false,
        profile: true,
        owner: true,
    };
    assert_eq!(told(&mut rx, w.bob.id), expected);

    ok(&w.app, &w.bob.token, "GET", "/me", None).await;
    assert_eq!(told(&mut rx, w.bob.id), Told::default(), "told twice");
}
