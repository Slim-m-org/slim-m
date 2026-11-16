// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An invite that grants a role is role assignment with a delay, so the grant is checked again
//! when the code is spent: a maker who could no longer give that role by hand gives nobody the role.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;

use crate::support;
use support::app::{app, call, call_as, register_account};

/// alice owns the Space; mia holds `mod` above `helper` and made a reusable invite granting `helper`.
struct World {
    app: Router,
    store: Store,
    pool: sqlx::SqlitePool,
    admin: RoleId,
    mods: RoleId,
    helper: RoleId,
    mia: UserId,
    code: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(name).await;
    let app = app(store.clone());
    register_account(&store, "alice").await;
    let mia = register_account(&store, "mia").await;
    let kick = Permissions::KICK_MEMBERS;
    let managing = Permissions::MANAGE_ROLES
        .union(Permissions::CREATE_INVITE)
        .union(kick);
    let mods = store.create_role("mod", managing, false).await.unwrap();
    let helper = store.create_role("helper", kick, false).await.unwrap();
    let admin = store.list_roles().await.unwrap();
    let admin = admin.into_iter().find(|r| r.name == "admin").unwrap().id;
    store.reorder_roles(&[admin, mods, helper]).await.unwrap();
    store.assign_role(mia.id, mods).await.unwrap();
    let invite = json!({ "role_grant": helper.to_string() });
    let (status, body) = call_as(&app, "POST", "/invites", &mia.token, Some(invite)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    World {
        code: body["code"].as_str().unwrap().to_owned(),
        app,
        store,
        pool,
        admin,
        mods,
        helper,
        mia: mia.id,
        _guard: guard,
    }
}

impl World {
    /// Registers `username` with the code and answers whether they came in holding `helper`.
    async fn joins_with_helper(&self, username: &str) -> bool {
        let body = json!({
            "username": username,
            "display_name": username,
            "password": "a-long-enough-password",
            "device_name": "cli",
            "invite_code": self.code,
        });
        let (status, body): (StatusCode, Value) =
            call(&self.app, "POST", "/auth/register", None, Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let user = self
            .store
            .find_credentials(username)
            .await
            .unwrap()
            .unwrap()
            .0;
        self.store.holds_role(user, self.helper).await.unwrap()
    }
}

#[tokio::test]
async fn a_maker_who_still_could_grant_the_role_gives_it() {
    let w = world("slimm-invite-recheck-ok").await;
    assert!(w.joins_with_helper("first").await);
}

#[tokio::test]
async fn a_demoted_maker_gives_nobody_the_role() {
    let w = world("slimm-invite-recheck-demoted").await;
    w.store.unassign_role(w.mia, w.mods).await.unwrap();
    assert!(!w.joins_with_helper("late").await);
}

#[tokio::test]
async fn a_role_moved_above_its_maker_is_not_given() {
    let w = world("slimm-invite-recheck-moved").await;
    w.store
        .reorder_roles(&[w.admin, w.helper, w.mods])
        .await
        .unwrap();
    assert!(!w.joins_with_helper("late").await);
}

/// The existing-member path spends the code the same way.
#[tokio::test]
async fn a_role_grown_past_its_maker_is_not_given_to_a_member_either() {
    let w = world("slimm-invite-recheck-grown").await;
    sqlx::query("UPDATE roles SET permissions = ? WHERE id = ?")
        .bind(
            Permissions::KICK_MEMBERS
                .union(Permissions::BAN_MEMBERS)
                .bits(),
        )
        .bind(w.helper)
        .execute(&w.pool)
        .await
        .unwrap();
    assert!(!w.joins_with_helper("late").await);
    let member = register_account(&w.store, "member").await;
    let uri = format!("/invites/{}/redeem", w.code);
    let (status, body) = call_as(&w.app, "POST", &uri, &member.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert!(!w.store.holds_role(member.id, w.helper).await.unwrap());
}
