// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector's token and approval reach what its principal holds, so only a manager who holds
//! it all and outranks the principal may install, update or re-key one, and every change to
//! its grants is announced to live sockets and role lists.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::hub::Event;
use slimm_server::ids::{ChannelId, RoleId, UserId};
use slimm_server::permissions::Permissions;
use tokio::sync::broadcast::Receiver;

use super::harness::{ID, World, world};
use crate::support::app::register_account;

const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();
const BAN: i64 = Permissions::BAN_MEMBERS.bits();

struct Manager {
    role: RoleId,
    token: String,
}

/// A manager who holds MANAGE_SERVER and `extra`, below the owner.
async fn manager(w: &World, extra: Permissions) -> Manager {
    let account = register_account(&w.store, "ops").await;
    let role = w
        .store
        .create_role("ops", Permissions::MANAGE_SERVER.union(extra), false)
        .await
        .unwrap();
    w.store.assign_role(account.id, role).await.unwrap();
    Manager {
        role,
        token: account.token,
    }
}

fn token_uri() -> String {
    format!("/space/dock/modules/{ID}/connector-token")
}

async fn reissue_as(w: &World, who: &Manager) -> StatusCode {
    w.as_token(&who.token, "POST", &token_uri(), None).await.0
}

async fn install_as(w: &World, who: &Manager, approved: i64) -> StatusCode {
    let (_, shown) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
        .await;
    let body = json!({
        "version": shown["version"],
        "reviewed_digest": shown["review_digest"],
        "approved_connector_permissions": approved,
    });
    w.as_token(
        &who.token,
        "POST",
        &format!("/space/dock/modules/{ID}/install"),
        Some(body),
    )
    .await
    .0
}

async fn principal_and_role(w: &World) -> (UserId, RoleId) {
    let principal = w
        .store
        .installed_module(ID)
        .await
        .unwrap()
        .and_then(|m| m.bot_user_id)
        .unwrap();
    let role = w.store.role_for_bot(principal).await.unwrap().unwrap().id;
    (principal, role)
}

/// Ranks `order` at the bottom of the ladder, first entry highest.
async fn rank(w: &World, order: &[RoleId]) {
    let mut ids: Vec<RoleId> = w
        .store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .filter(|r| !r.is_everyone && !order.contains(&r.id))
        .map(|r| r.id)
        .collect();
    ids.extend_from_slice(order);
    w.store.reorder_roles(&ids).await.unwrap();
}

async fn bots_role(w: &World) -> RoleId {
    w.store
        .list_roles()
        .await
        .unwrap()
        .into_iter()
        .find(|r| r.is_bots_role)
        .unwrap()
        .id
}

#[tokio::test]
async fn a_manager_without_the_connectors_bits_cannot_reissue_its_token() {
    let w = world("slimm-conn-esc-bits", &["view_channel", "ban_members"]).await;
    let token = w.installed(VIEW | BAN).await;
    let ops = manager(&w, Permissions::NONE).await;

    assert_eq!(reissue_as(&w, &ops).await, StatusCode::FORBIDDEN);
    let (status, _) = w.as_token(&token, "GET", "/connectors/me", None).await;
    assert_eq!(status, StatusCode::OK, "the refused call kept the token");
}

#[tokio::test]
async fn a_manager_below_the_connector_on_the_ladder_cannot_reissue_its_token() {
    let w = world("slimm-conn-esc-rank", &["view_channel"]).await;
    w.installed(VIEW).await;
    let ops = manager(&w, Permissions::VIEW_CHANNEL).await;
    let (_, own) = principal_and_role(&w).await;
    let bots = bots_role(&w).await;
    rank(&w, &[own, ops.role, bots]).await;

    assert_eq!(reissue_as(&w, &ops).await, StatusCode::FORBIDDEN);
    rank(&w, &[ops.role, own, bots]).await;
    let (status, body) = w.as_token(&ops.token, "POST", &token_uri(), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn a_manager_without_the_connectors_bits_cannot_update_its_install() {
    let w = world("slimm-conn-esc-update", &["view_channel"]).await;
    w.installed(VIEW).await;
    let ops = manager(&w, Permissions::NONE).await;

    assert_eq!(install_as(&w, &ops, 0).await, StatusCode::FORBIDDEN);
    let kept = w.store.installed_module(ID).await.unwrap().unwrap();
    assert_eq!(
        kept.connector_permissions.map(Permissions::bits),
        Some(VIEW)
    );
}

#[tokio::test]
async fn a_manager_below_the_shared_bots_role_cannot_install_a_connector() {
    let w = world("slimm-conn-esc-install", &["view_channel"]).await;
    let ops = manager(&w, Permissions::VIEW_CHANNEL).await;
    w.store
        .create_bot_with_prefix("helper", "helper", Permissions::NONE, w.owner.id, Some("!"))
        .await
        .unwrap();
    let bots = bots_role(&w).await;
    rank(&w, &[bots, ops.role]).await;

    assert_eq!(install_as(&w, &ops, VIEW).await, StatusCode::FORBIDDEN);
    assert!(w.store.installed_module(ID).await.unwrap().is_none());
}

fn drain(rx: &mut Receiver<Event>) -> Vec<Event> {
    std::iter::from_fn(|| rx.try_recv().ok())
        .map(|event| match event {
            Event::Stamped { event, .. } => *event,
            other => other,
        })
        .collect()
}

fn role_changes(events: &[Event]) -> Vec<RoleId> {
    events
        .iter()
        .filter_map(|e| match e {
            Event::RoleChanged { role_id, .. } => Some(*role_id),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn updating_and_toggling_a_connector_announce_its_role() {
    let w = world(
        "slimm-conn-esc-role-events",
        &["view_channel", "ban_members"],
    )
    .await;
    w.installed(VIEW).await;
    let (_, role) = principal_and_role(&w).await;
    let mut rx = w.state.hub.subscribe();

    let (status, body) = w.install(Some(VIEW | BAN)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(role_changes(&drain(&mut rx)).contains(&role), "update");

    w.set_enabled(false).await;
    assert!(role_changes(&drain(&mut rx)).contains(&role), "disable");
    w.set_enabled(true).await;
    assert!(role_changes(&drain(&mut rx)).contains(&role), "enable");
}

#[tokio::test]
async fn uninstalling_a_connector_announces_its_role_and_overwrites() {
    let w = world("slimm-conn-esc-uninstall-events", &["view_channel"]).await;
    w.installed(VIEW).await;
    let (principal, role) = principal_and_role(&w).await;
    let general = ChannelId(w.general().await.parse().unwrap());
    w.store
        .set_member_overwrite(
            general,
            principal,
            Permissions::VIEW_CHANNEL,
            Permissions::NONE,
        )
        .await
        .unwrap();
    let mut rx = w.state.hub.subscribe();

    let (status, _) = w
        .as_owner("DELETE", &format!("/space/dock/modules/{ID}/install"), None)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let events = drain(&mut rx);
    assert!(role_changes(&events).contains(&role), "role");
    assert!(
        events.iter().any(|e| matches!(
            e,
            Event::OverwriteChanged { channel_id, previously_visible_to }
                if *channel_id == general && previously_visible_to.contains(&principal)
        )),
        "overwrite"
    );
}
