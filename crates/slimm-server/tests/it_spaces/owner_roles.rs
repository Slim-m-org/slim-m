// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What keeps the Space owner able to recover the roles: the owner holds every permission
//! whatever happens to a role they hold, and the last human holding ADMINISTRATOR cannot leave it
//! to bots alone.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{RoleId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{DeleteAccountError, Store};

use crate::support;
use support::app::{app, call_as, register_account};

struct World {
    app: Router,
    store: Store,
    alice: support::app::Account,
    admin: RoleId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-owner-roles").await;
    let app = app(store.clone());
    let alice = register_account(&store, "alice").await;
    let admin = store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.name == "admin")
        .unwrap()
        .id;
    World {
        app,
        store,
        alice,
        admin,
        _guard: guard,
    }
}

fn refused(result: (StatusCode, Value)) {
    assert_eq!(result.0, StatusCode::FORBIDDEN, "{}", result.1);
    assert_eq!(result.1["code"], "role_hierarchy", "{}", result.1);
}

/// The owner holds ADMINISTRATOR only through `ops`, low on the list, below frank's `admin`.
#[tokio::test]
async fn an_administrator_above_may_hollow_out_the_owners_role_and_the_owner_keeps_everything() {
    let w = world().await;
    let frank = register_account(&w.store, "frank").await;
    let admin_bit = Permissions::ADMINISTRATOR;
    let ops = w.store.create_role("ops", admin_bit, false).await.unwrap();
    w.store.reorder_roles(&[w.admin, ops]).await.unwrap();
    w.store.assign_role(w.alice.id, ops).await.unwrap();
    w.store.assign_role(frank.id, w.admin).await.unwrap();
    let own = format!("/members/{}/roles/{}", w.alice.id, w.admin);
    let (status, body) = call_as(&w.app, "DELETE", &own, &w.alice.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");

    let role = format!("/roles/{ops}");
    let hollow = json!({ "permissions": 0 });
    let (status, body) = call_as(&w.app, "PATCH", &role, &frank.token, Some(hollow)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        w.store.base_permissions(w.alice.id).await.unwrap(),
        Permissions::ALL
    );
    let (status, body) = call_as(&w.app, "DELETE", &role, &frank.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert_eq!(
        w.store.base_permissions(w.alice.id).await.unwrap(),
        Permissions::ALL
    );

    refused(call_as(&w.app, "PUT", &own, &frank.token, None).await);
    let take = format!("/members/{}/roles/{}", frank.id, w.admin);
    let (status, body) = call_as(&w.app, "DELETE", &take, &w.alice.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
}

/// A bot holding ADMINISTRATOR cannot be the heir and stands at the bottom of the list; the
/// owner dropping `admin` leaves nobody stranded, since the owner still holds everything.
#[tokio::test]
async fn the_last_human_administrator_cannot_leave_the_roles_to_a_bot() {
    let w = world().await;
    let bob = register_account(&w.store, "bob").await;
    let admin_bit = Permissions::ADMINISTRATOR;
    let warden = w
        .store
        .create_bot("warden", "warden", admin_bit, w.alice.id);
    warden.await.unwrap();

    let own = format!("/members/{}/roles/{}", w.alice.id, w.admin);
    let (status, body) = call_as(&w.app, "DELETE", &own, &w.alice.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    let left = w.store.delete_account(w.alice.id).await;
    assert!(
        matches!(left, Err(DeleteAccountError::WouldStrandDeployment)),
        "{left:?}"
    );

    w.store.delete_account(bob.id).await.unwrap();
    w.store.delete_account(w.alice.id).await.unwrap();
    assert_eq!(w.store.space_owner().await.unwrap(), None::<UserId>);
}
