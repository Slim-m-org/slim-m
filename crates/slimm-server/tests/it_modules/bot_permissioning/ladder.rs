// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's token acts with every role the bot holds, so only someone holding all of it and
//! ranking above the bot on the role ladder may create, re-key, revoke or repermission one.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::bot_permissioning::harness::{
    admin, app, create_bot, harness, json_body, member, request,
};

/// root owns the Space; ops holds MANAGE_SERVER and KICK_MEMBERS; modbot was made by root with
/// KICK_MEMBERS, so it holds its own role and the shared Bots role.
struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    ops_token: String,
    admin: RoleId,
    ops: RoleId,
    bots: RoleId,
    own: RoleId,
    modbot: UserId,
    _guard: crate::support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, pool, guard) = harness(name).await;
    let (_root_id, root) = admin(&store, "root").await;
    let app = app(store.clone());
    let (ops_id, ops_token) = member(&store, "ops").await;
    let managing = Permissions::MANAGE_SERVER.union(Permissions::KICK_MEMBERS);
    let ops = store.create_role("ops", managing, false).await.unwrap();
    store.assign_role(ops_id, ops).await.unwrap();
    let kick = Permissions::KICK_MEMBERS.bits();
    let (modbot, _token, status) = create_bot(&app, &root, "modbot", kick).await;
    assert_eq!(status, StatusCode::CREATED);
    let modbot = UserId(modbot.parse().unwrap());
    let roles = store.list_roles().await.unwrap();
    let id_of = |pick: &dyn Fn(&slimm_server::store::Role) -> bool| {
        roles.iter().find(|r| pick(r)).unwrap().id
    };
    World {
        admin: id_of(&|r| r.name == "admin"),
        bots: id_of(&|r| r.is_bots_role),
        own: id_of(&|r| r.managed_bot_id == Some(modbot)),
        app,
        store,
        pool,
        ops_token,
        ops,
        modbot,
        _guard: guard,
    }
}

impl World {
    /// Puts `below_admin` under `admin`, top first.
    async fn order(&self, below_admin: &[RoleId]) {
        let mut ids = vec![self.admin];
        ids.extend_from_slice(below_admin);
        self.store.reorder_roles(&ids).await.unwrap();
    }

    async fn as_ops(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let response = self
            .app
            .clone()
            .oneshot(request(method, uri, &self.ops_token, body))
            .await
            .unwrap();
        let status = response.status();
        (status, json_body(response).await)
    }

    /// Every verb that hands ops the bot's power, each refused.
    async fn all_refused(&self) {
        let bot = self.modbot;
        for (method, uri, body) in [
            ("POST", format!("/bots/{bot}/token"), None),
            ("POST", format!("/bots/{bot}/revoke"), None),
            (
                "PATCH",
                format!("/bots/{bot}/permissions"),
                Some(json!({ "permissions": 0 })),
            ),
            (
                "PATCH",
                format!("/bots/{bot}/prefix"),
                Some(json!({ "prefix": "?" })),
            ),
        ] {
            let (status, body) = self.as_ops(method, &uri, body).await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{method} {uri}: {body}");
        }
        assert!(self.store.role(self.own).await.unwrap().is_some());
    }
}

#[tokio::test]
async fn a_manager_above_the_bot_holding_all_it_holds_re_keys_it() {
    let w = world("slimm-bot-ladder-reach").await;
    w.order(&[w.ops, w.bots, w.own]).await;
    let (status, body) = w
        .as_ops("POST", &format!("/bots/{}/token", w.modbot), None)
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

/// The managed role carries only bits ops holds, but a second role, still below ops, hands the bot more.
#[tokio::test]
async fn a_role_handed_to_the_bot_by_hand_keeps_a_weaker_manager_off_it() {
    let w = world("slimm-bot-ladder-extra-role").await;
    let bits = Permissions::BAN_MEMBERS.union(Permissions::MANAGE_ROLES);
    let moderator = w.store.create_role("moderator", bits, false).await.unwrap();
    w.store.assign_role(w.modbot, moderator).await.unwrap();
    w.order(&[w.ops, moderator, w.bots, w.own]).await;
    w.all_refused().await;
}

/// Bits alone are not enough: a bot whose role was moved above the manager outranks them.
#[tokio::test]
async fn a_bot_ranked_above_the_manager_is_out_of_reach() {
    let w = world("slimm-bot-ladder-rank").await;
    w.order(&[w.own, w.ops, w.bots]).await;
    let uri = format!("/bots/{}/token", w.modbot);
    let (status, body) = w.as_ops("POST", &uri, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");
    w.all_refused().await;
}

/// A new bot holds the shared Bots role, so its maker must outrank it and hold what it grants.
#[tokio::test]
async fn creating_a_bot_needs_reach_over_the_bots_role_and_its_bits() {
    let w = world("slimm-bot-ladder-create").await;
    let create = |name: &str| Some(json!({ "username": name, "permissions": 0 }));
    w.order(&[w.bots, w.ops, w.own]).await;
    let (status, body) = w.as_ops("POST", "/bots", create("above")).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["code"], "role_hierarchy");

    w.order(&[w.ops, w.bots, w.own]).await;
    let (status, body) = w.as_ops("POST", "/bots", create("below")).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    sqlx::query("UPDATE roles SET permissions = ? WHERE id = ?")
        .bind(Permissions::BAN_MEMBERS.bits())
        .bind(w.bots)
        .execute(&w.pool)
        .await
        .unwrap();
    let (status, body) = w.as_ops("POST", "/bots", create("banner")).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
}
