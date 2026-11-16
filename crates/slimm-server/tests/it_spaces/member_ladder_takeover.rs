// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The role ladder on the acts that hand over or hand back an account: an administrator's reset
//! code and second-factor clear, and restoring a removed member, reach only members ranked below.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
use support::app::{app, call_as};
use support::overwrite_harness::{KNOWN_PASSWORD, register_with_password as register};

/// alice owns the Space; erin and dave hold `admin` with her, mallory and mo hold `mod`, frank nothing.
struct World {
    app: Router,
    store: Store,
    alice: (String, String),
    erin: (String, String),
    dave: (String, String),
    mallory: (String, String),
    mo: (String, String),
    frank: (String, String),
    _guard: support::TestDbGuard,
}

async fn ok(app: &Router, token: &str, method: &str, uri: &str, body: Option<Value>) -> Value {
    let (status, body) = call_as(app, method, uri, token, body).await;
    assert!(status.is_success(), "{method} {uri}: {status} {body}");
    body
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-member-ladder-takeover").await;
    let app = app(store.clone());
    let alice = register(&store, "alice").await;
    let erin = register(&store, "erin").await;
    let dave = register(&store, "dave").await;
    let mallory = register(&store, "mallory").await;
    let mo = register(&store, "mo").await;
    let frank = register(&store, "frank").await;
    let bits = Permissions::BAN_MEMBERS.bits();
    let body = json!({ "name": "mod", "permissions": bits });
    let mods = ok(&app, &alice.0, "POST", "/roles", Some(body)).await["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let admin = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id
        .to_string();
    for (user, role) in [
        (&erin, &admin),
        (&dave, &admin),
        (&mallory, &mods),
        (&mo, &mods),
    ] {
        let uri = format!("/members/{}/roles/{role}", user.1);
        ok(&app, &alice.0, "PUT", &uri, None).await;
    }
    World {
        app,
        store,
        alice,
        erin,
        dave,
        mallory,
        mo,
        frank,
        _guard: guard,
    }
}

fn password() -> Option<Value> {
    Some(json!({ "password": KNOWN_PASSWORD }))
}

fn refused(result: (StatusCode, Value)) {
    assert_eq!(result.0, StatusCode::FORBIDDEN, "{}", result.1);
    assert_eq!(result.1["code"], "role_hierarchy", "{}", result.1);
}

impl World {
    async fn reset_code(&self, actor: &(String, String), target: &str) -> (StatusCode, Value) {
        let uri = format!("/admin/users/{target}/reset-code");
        call_as(&self.app, "POST", &uri, &actor.0, password()).await
    }

    async fn clear_factor(&self, actor: &(String, String), target: &str) -> (StatusCode, Value) {
        let uri = format!("/admin/users/{target}/totp");
        call_as(&self.app, "DELETE", &uri, &actor.0, password()).await
    }

    async fn restore(&self, actor: &(String, String), target: &str) -> StatusCode {
        let uri = format!("/members/{target}/removal");
        call_as(&self.app, "DELETE", &uri, &actor.0, None).await.0
    }

    async fn remove(&self, target: &str) {
        let uri = format!("/members/{target}/removal");
        ok(&self.app, &self.alice.0, "PUT", &uri, Some(json!({}))).await;
    }

    async fn is_removed(&self, user: &str) -> bool {
        let removed = self.store.list_removals().await.unwrap();
        removed.iter().any(|r| r.user_id.to_string() == user)
    }
}

/// A reset code or a cleared factor takes the account over, the owner's included.
#[tokio::test]
async fn an_administrator_cannot_take_over_the_owner_or_a_peer() {
    let w = world().await;
    for target in [&w.alice.1, &w.dave.1] {
        refused(w.reset_code(&w.erin, target).await);
        refused(w.clear_factor(&w.erin, target).await);
    }
    let (status, body) = w.reset_code(&w.erin, &w.frank.1).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, body) = w.reset_code(&w.alice, &w.erin.1).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, body) = w.clear_factor(&w.alice, &w.erin.1).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "past the ladder, erin has no factor: {body}"
    );
}

/// A removed member keeps their roles, so letting them back in is gated like the removal.
#[tokio::test]
async fn a_moderator_cannot_restore_someone_they_could_not_have_removed() {
    let w = world().await;
    w.remove(&w.erin.1).await;
    w.remove(&w.mo.1).await;
    w.remove(&w.frank.1).await;
    assert_eq!(
        w.restore(&w.mallory, &w.erin.1).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(w.restore(&w.mallory, &w.mo.1).await, StatusCode::FORBIDDEN);
    assert!(w.is_removed(&w.erin.1).await && w.is_removed(&w.mo.1).await);
    assert_eq!(
        w.restore(&w.mallory, &w.frank.1).await,
        StatusCode::NO_CONTENT
    );
    assert_eq!(w.restore(&w.alice, &w.erin.1).await, StatusCode::NO_CONTENT);
}
