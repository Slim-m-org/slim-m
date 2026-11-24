// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A registration invite code is a credential, so who may read one back off a
//! member list is a privilege question, not a display question.
//!
//! Split from `tests/it_accounts/invites.rs`, which is at its file-budget entry and covers
//! issuing, spending and expiry. This holds the disclosure side: `redeem` needs
//! nothing but a session and applies the invite's `role_grant` to whoever
//! spends it, so a caller who could not grant that role must not be handed a
//! still-live code for it.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::auth::Auth;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::{app, json_body_or_null as json_body, request};

/// An admin who claimed the deployment, and a plain member, both with sessions.
async fn fixture() -> (Store, Router, String, String, support::TestDbGuard) {
    let (store, guard) = support::new_store("slimm-invite-disclosure").await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("admin", "Admin", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("member", "Member", &hash)
        .await
        .unwrap();
    let admin_session = store.open_session(admin.id, "d").await.unwrap();
    let member_session = store.open_session(member.id, "d").await.unwrap();
    let app = app(store.clone());
    (
        store,
        app,
        admin_session.access_token,
        member_session.access_token,
        guard,
    )
}

/// Grants `bits` to the ordinary member, so a test holds exactly the
/// permissions it is about and nothing else.
async fn grant_member(store: &Store, bits: Permissions) {
    let member = store.find_credentials("member").await.unwrap().unwrap().0;
    let role = store.create_role("granted", bits, false).await.unwrap();
    store.assign_role(member, role).await.unwrap();
}

/// A registration code is a credential, not a label: `redeem` hands its
/// `role_grant` to whoever spends it. `GET /members` used to attach the raw
/// code for any BAN_MEMBERS holder, so a moderator who could not grant a
/// role could read the code off the list and take it. The ban-evasion
/// signal now needs MANAGE_ROLES, the permission that could grant it anyway.
#[tokio::test]
async fn a_moderator_without_manage_roles_cannot_read_a_registration_code() {
    let (store, app, admin, member, _guard) = fixture().await;
    grant_member(&store, Permissions::BAN_MEMBERS).await;

    let role = store
        .create_role("elevated", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    let created = app
        .clone()
        .oneshot(request(
            "POST",
            "/invites",
            Some(&admin),
            Some(json!({ "role_grant": role.to_string() })),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let code = json_body(created).await["code"]
        .as_str()
        .unwrap()
        .to_owned();

    let registered = app
        .clone()
        .oneshot(request(
            "POST",
            "/auth/register",
            None,
            Some(json!({
                "username": "carol",
                "display_name": "Carol",
                "password": "hunter2hunter2",
                "device_name": "cli",
                "invite_code": code,
            })),
        ))
        .await
        .unwrap();
    assert_eq!(registered.status(), StatusCode::OK);

    let listed = app
        .clone()
        .oneshot(request("GET", "/members", Some(&member), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let members = json_body(listed).await;
    let carol = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == "carol")
        .expect("carol is listed");
    assert!(
        carol["invite_code"].is_null(),
        "BAN_MEMBERS alone must not see the code, which is redeemable for {role}"
    );

    // The signal is not lost: whoever could grant the role still sees it.
    let as_admin = app
        .oneshot(request("GET", "/members", Some(&admin), None))
        .await
        .unwrap();
    let members = json_body(as_admin).await;
    let carol = members
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == "carol")
        .unwrap();
    assert_eq!(carol["invite_code"].as_str(), Some(code.as_str()));
}

/// The `invite_code` each row of `GET {uri}` shows for `username`, as `caller` reads it.
async fn code_on_row(app: &Router, uri: &str, caller: &str, username: &str) -> Option<String> {
    let listed = app
        .clone()
        .oneshot(request("GET", uri, Some(caller), None))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK, "{uri}");
    let rows = json_body(listed).await;
    let row = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["username"] == username)
        .unwrap_or_else(|| panic!("{username} is listed on {uri}"))
        .clone();
    row["invite_code"].as_str().map(str::to_owned)
}

/// The member lists show a code only where `GET /invites` would: a manager below a role is not
/// handed a live code that grants it.
#[tokio::test]
async fn a_manager_below_a_role_cannot_read_a_code_that_grants_it_off_either_list() {
    let (store, app, admin, member, _guard) = fixture().await;
    let managing = Permissions::MANAGE_ROLES
        .union(Permissions::CREATE_INVITE)
        .union(Permissions::BAN_MEMBERS);
    let manager = store.create_role("manager", managing, false).await.unwrap();
    let staff = store
        .create_role("staff", Permissions::BAN_MEMBERS, false)
        .await
        .unwrap();
    let owner_role = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id;
    store
        .reorder_roles(&[owner_role, staff, manager])
        .await
        .unwrap();
    let member_id = store.find_credentials("member").await.unwrap().unwrap().0;
    store.assign_role(member_id, manager).await.unwrap();

    let mint = |body: serde_json::Value| {
        let app = app.clone();
        let admin = admin.clone();
        async move {
            let created = app
                .oneshot(request("POST", "/invites", Some(&admin), Some(body)))
                .await
                .unwrap();
            assert_eq!(created.status(), StatusCode::OK);
            json_body(created).await["code"]
                .as_str()
                .unwrap()
                .to_owned()
        }
    };
    let staff_code = mint(json!({ "role_grant": staff.to_string() })).await;
    let plain_code = mint(json!({})).await;
    let carol = store
        .register_account("carol", "Carol", "h", Some(&staff_code))
        .await
        .unwrap();
    store
        .register_account("dave", "Dave", "h", Some(&plain_code))
        .await
        .unwrap();

    assert_eq!(code_on_row(&app, "/members", &member, "carol").await, None);
    assert_eq!(
        code_on_row(&app, "/members", &member, "dave").await,
        Some(plain_code.clone()),
        "a code that grants nothing is one the manager lists in GET /invites too"
    );
    assert_eq!(
        code_on_row(&app, "/members", &admin, "carol").await,
        Some(staff_code.clone())
    );

    let admin_id = store.find_credentials("admin").await.unwrap().unwrap().0;
    store
        .remove_from_space(carol.id, admin_id, None)
        .await
        .unwrap();
    assert_eq!(
        code_on_row(&app, "/members/removed", &member, "carol").await,
        None
    );
    assert_eq!(
        code_on_row(&app, "/members/removed", &admin, "carol").await,
        Some(staff_code)
    );
}
