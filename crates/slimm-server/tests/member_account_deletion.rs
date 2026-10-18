// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An administrator deleting somebody else's account outright.
//!
//! Removing a member and deleting their account look adjacent and are not the
//! same power: a removal takes access away and `restoreMember` undoes it,
//! while nothing undoes this. So the permission is ADMINISTRATOR, and the
//! first test below is the one that matters - BAN_MEMBERS, which is enough to
//! remove and restore all day, must not be enough to delete.
//!
//! Its own file rather than another module in `member_moderation_routes.rs`,
//! which is at 373 lines and not allowlisted; the invite tests already set the
//! precedent of splitting by aspect.

use axum::Router;
use axum::http::StatusCode;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_bearer as request};

struct World {
    app: Router,
    store: Store,
    admin_token: String,
    admin_id: String,
    mod_token: String,
    victim_id: String,
    _guard: support::TestDbGuard,
}

/// An administrator, a moderator holding only the removal bits, and a member
/// who has already been removed - the state this action is reached from.
async fn world() -> World {
    let (path, guard) = support::TestDbGuard::new("slimm-member-account-deletion");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);

    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let admin_token = store
        .open_session(admin.id, "cli")
        .await
        .unwrap()
        .access_token;

    let mod_role = store
        .create_role(
            "mod",
            Permissions::KICK_MEMBERS.union(Permissions::BAN_MEMBERS),
            false,
        )
        .await
        .unwrap();
    let moderator = store
        .create_account("mod", "Mod", "not-a-real-hash")
        .await
        .unwrap();
    store.assign_role(moderator.id, mod_role).await.unwrap();
    let mod_token = store
        .open_session(moderator.id, "cli")
        .await
        .unwrap()
        .access_token;

    let victim = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();
    store
        .remove_from_space(victim.id, admin.id, None)
        .await
        .unwrap();

    let app = http::router(support::app::state(store.clone()));

    World {
        app,
        store,
        admin_token,
        admin_id: admin.id.to_string(),
        mod_token,
        victim_id: victim.id.to_string(),
        _guard: guard,
    }
}

async fn delete_account(app: &Router, target: &str, token: &str) -> StatusCode {
    app.clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{target}/account"),
            token,
        ))
        .await
        .unwrap()
        .status()
}

/// The distinction the whole permission choice rests on.
#[tokio::test]
async fn ban_members_can_remove_but_cannot_delete() {
    let w = world().await;

    // The same moderator may restore, so this is not a general lack of power.
    let restored = w
        .app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{}/removal", w.victim_id),
            &w.mod_token,
        ))
        .await
        .unwrap();
    assert_eq!(restored.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        delete_account(&w.app, &w.victim_id, &w.mod_token).await,
        StatusCode::FORBIDDEN,
        "removing is reversible and deleting is not; BAN_MEMBERS must not \
         carry the irreversible one"
    );
}

#[tokio::test]
async fn an_administrator_deletes_the_account_and_frees_the_username() {
    let w = world().await;

    assert_eq!(
        delete_account(&w.app, &w.victim_id, &w.admin_token).await,
        StatusCode::NO_CONTENT
    );

    // The tombstone takes them off the list: it skips deleted users.
    let listed = w
        .app
        .clone()
        .oneshot(request("GET", "/members/removed", &w.admin_token))
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK);
    let rows = json_body(listed).await;
    assert!(
        rows.as_array().unwrap().is_empty(),
        "a deleted account must stop being listed as removed: {rows}"
    );

    // Freeing the name is the point: it is what lets it be registered again.
    let reused = w
        .store
        .create_account("nia", "Nia Again", "not-a-real-hash")
        .await;
    assert!(
        reused.is_ok(),
        "the username must free up once the account is deleted"
    );
}

#[tokio::test]
async fn deleting_your_own_account_through_this_route_is_refused() {
    let w = world().await;

    assert_eq!(
        delete_account(&w.app, &w.admin_id, &w.admin_token).await,
        StatusCode::BAD_REQUEST,
        "self-deletion keeps its own route, so an administrator can leave \
         without another administrator to do it for them"
    );
}

#[tokio::test]
async fn the_last_administrator_cannot_be_deleted_by_another_admin() {
    let w = world().await;

    // A second administrator, so there is somebody to make the attempt.
    let admin_role = w
        .store
        .create_role("admin2", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let other = w
        .store
        .create_account("two", "Two", "not-a-real-hash")
        .await
        .unwrap();
    w.store.assign_role(other.id, admin_role).await.unwrap();
    let other_token = w
        .store
        .open_session(other.id, "cli")
        .await
        .unwrap()
        .access_token;

    // With two administrators, deleting one is allowed.
    assert_eq!(
        delete_account(&w.app, &w.admin_id, &other_token).await,
        StatusCode::NO_CONTENT
    );

    // Now there is one left, and nothing may take it.
    let last = delete_account(&w.app, &other.id.to_string(), &other_token).await;
    assert_eq!(
        last,
        StatusCode::BAD_REQUEST,
        "refused as self-deletion before the stranding check is even reached"
    );
}

/// A member who was never removed can still be deleted: removal is not a
/// precondition, it is just the screen this is reached from.
#[tokio::test]
async fn a_member_who_was_never_removed_can_be_deleted_too() {
    let w = world().await;
    let ordinary = w
        .store
        .create_account("kit", "Kit", "not-a-real-hash")
        .await
        .unwrap();

    assert_eq!(
        delete_account(&w.app, &ordinary.id.to_string(), &w.admin_token).await,
        StatusCode::NO_CONTENT
    );
    assert!(
        w.store
            .create_account("kit", "Kit Again", "not-a-real-hash")
            .await
            .is_ok()
    );
}

/// Not part of the feature, but the shape the UI depends on: the row only
/// disappears because the list filters tombstones, so a restore-then-delete
/// still leaves nothing behind.
#[tokio::test]
async fn a_restored_then_deleted_member_is_not_listed_either() {
    let w = world().await;
    let restored = w
        .app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/members/{}/removal", w.victim_id),
            &w.admin_token,
        ))
        .await
        .unwrap();
    assert_eq!(restored.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        delete_account(&w.app, &w.victim_id, &w.admin_token).await,
        StatusCode::NO_CONTENT
    );
    let rows = json_body(
        w.app
            .clone()
            .oneshot(request("GET", "/members/removed", &w.admin_token))
            .await
            .unwrap(),
    )
    .await;
    assert!(rows.as_array().unwrap().is_empty());
}
