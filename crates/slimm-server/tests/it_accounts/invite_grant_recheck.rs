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
    alice: support::app::Account,
    admin: RoleId,
    mods: RoleId,
    helper: RoleId,
    mia: UserId,
    mia_token: String,
    code: String,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, pool, guard) = support::new_store_with_pool(name).await;
    let app = app(store.clone());
    let alice = register_account(&store, "alice").await;
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
        alice,
        admin,
        mods,
        helper,
        mia: mia.id,
        mia_token: mia.token.clone(),
        _guard: guard,
    }
}

impl World {
    /// An invite the owner makes, granting `role`.
    async fn mint(&self, role: RoleId) -> String {
        let invite = json!({ "role_grant": role.to_string() });
        let (status, body) = call_as(
            &self.app,
            "POST",
            "/invites",
            &self.alice.token,
            Some(invite),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["code"].as_str().unwrap().to_owned()
    }

    /// Registers `username` with the code and answers whether they came in holding `helper`.
    async fn joins_with_helper(&self, username: &str) -> bool {
        self.joins_holding(username, &self.code, self.helper).await
    }

    /// Registers `username` with `code` and answers whether they came in holding `role`.
    async fn joins_holding(&self, username: &str, code: &str, role: RoleId) -> bool {
        let body = json!({
            "username": username,
            "display_name": username,
            "password": "a-long-enough-password",
            "device_name": "cli",
            "invite_code": code,
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
        self.store.holds_role(user, role).await.unwrap()
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

/// The owner holds every permission with no role at all, so their grant stands when spent.
#[tokio::test]
async fn the_owner_with_no_roles_still_gives_the_role() {
    let w = world("slimm-invite-recheck-owner").await;
    let own = format!("/members/{}/roles/{}", w.alice.id, w.admin);
    let (status, body) = call_as(&w.app, "DELETE", &own, &w.alice.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    let invite = json!({ "role_grant": w.mods.to_string() });
    let (status, body) = call_as(&w.app, "POST", "/invites", &w.alice.token, Some(invite)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let code = body["code"].as_str().unwrap();
    assert!(w.joins_holding("guest", code, w.mods).await);
}

/// A manager below a role neither sees, revokes nor spends another person's invite for it.
#[tokio::test]
async fn a_lower_manager_neither_sees_nor_spends_a_senior_role_invite() {
    let w = world("slimm-invite-recheck-senior").await;
    let senior = w
        .store
        .create_role("senior", Permissions::NONE, false)
        .await
        .unwrap();
    w.store
        .reorder_roles(&[w.admin, senior, w.mods, w.helper])
        .await
        .unwrap();
    let senior_code = w.mint(senior).await;
    let helper_code = w.mint(w.helper).await;
    let mia_token = &w.mia_token;

    let (status, listed) = call_as(&w.app, "GET", "/invites", mia_token, None).await;
    assert_eq!(status, StatusCode::OK, "{listed}");
    let codes: Vec<&str> = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["code"].as_str().unwrap())
        .collect();
    assert!(!codes.contains(&senior_code.as_str()), "{listed}");
    assert!(codes.contains(&helper_code.as_str()), "{listed}");
    assert!(codes.contains(&w.code.as_str()), "{listed}");

    let revoke = format!("/invites/{senior_code}");
    let (status, _) = call_as(&w.app, "DELETE", &revoke, mia_token, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let redeem = format!("/invites/{senior_code}/redeem");
    let (status, body) = call_as(&w.app, "POST", &redeem, mia_token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert!(!w.store.holds_role(w.mia, senior).await.unwrap());
}
