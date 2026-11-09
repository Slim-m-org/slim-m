// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Granting a role names a member that must exist and must be able to hold it:
//! an unknown or deleted id is a 404 rather than a foreign-key 500, and a
//! webhook principal, which holds no roles, is a 400. Revoking stays idempotent.

use axum::Router;
use axum::http::StatusCode;
use slimm_server::ids::{RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, register_token_id as register, request};

struct World {
    store: Store,
    pool: sqlx::SqlitePool,
    router: Router,
    admin: String,
    admin_id: UserId,
    role: RoleId,
    _guard: support::TestDbGuard,
}

async fn world(prefix: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(prefix).await;
    let router = app(store.clone());
    let (admin, admin_id) = register(&store, "admin").await;
    let role = store
        .create_role("moderator", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    World {
        store,
        pool,
        router,
        admin,
        admin_id: UserId(Uuid::parse_str(&admin_id).unwrap()),
        role,
        _guard: guard,
    }
}

impl World {
    async fn call(&self, method: &str, user: &str) -> StatusCode {
        self.router
            .clone()
            .oneshot(request(
                method,
                &format!("/members/{user}/roles/{}", self.role),
                Some(&self.admin),
                None,
            ))
            .await
            .unwrap()
            .status()
    }

    async fn holds_role(&self, user: &str) -> bool {
        let user = UserId(Uuid::parse_str(user).unwrap());
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM member_roles WHERE user_id = ? AND role_id = ?",
        )
        .bind(user)
        .bind(self.role)
        .fetch_one(&self.pool)
        .await
        .unwrap()
            > 0
    }
}

#[tokio::test]
async fn granting_a_role_to_a_member_still_works() {
    let w = world("slimm-role-assign-ok").await;
    let (_, bob) = register(&w.store, "bob").await;
    assert_eq!(w.call("PUT", &bob).await, StatusCode::NO_CONTENT);
    assert!(w.holds_role(&bob).await);
}

#[tokio::test]
async fn granting_a_role_to_an_unknown_user_is_a_404_not_a_500() {
    let w = world("slimm-role-assign-unknown").await;
    let stranger = Uuid::now_v7().to_string();
    assert_eq!(w.call("PUT", &stranger).await, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn granting_a_role_to_a_deleted_user_is_a_404() {
    let w = world("slimm-role-assign-deleted").await;
    let (_, bob) = register(&w.store, "bob").await;
    sqlx::query("UPDATE users SET deleted_at = 1 WHERE id = ?")
        .bind(UserId(Uuid::parse_str(&bob).unwrap()))
        .execute(&w.pool)
        .await
        .unwrap();
    assert_eq!(w.call("PUT", &bob).await, StatusCode::NOT_FOUND);
    assert!(!w.holds_role(&bob).await);
}

#[tokio::test]
async fn granting_a_role_to_a_webhook_principal_is_a_400() {
    let w = world("slimm-role-assign-webhook").await;
    let channel = w.store.create_channel("alerts", "text").await.unwrap();
    let minted = w
        .store
        .create_webhook(channel.id, "hook", w.admin_id)
        .await
        .unwrap();
    let principal = minted.webhook.principal_id.to_string();

    assert_eq!(w.call("PUT", &principal).await, StatusCode::BAD_REQUEST);
    assert!(!w.holds_role(&principal).await);
}

#[tokio::test]
async fn revoking_a_role_from_an_unknown_user_stays_idempotent() {
    let w = world("slimm-role-unassign-unknown").await;
    let stranger = Uuid::now_v7().to_string();
    assert_eq!(w.call("DELETE", &stranger).await, StatusCode::NO_CONTENT);
}
