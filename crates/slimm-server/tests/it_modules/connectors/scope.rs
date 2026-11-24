// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector's token reaches only what the admin approved: not what
//! `@everyone` grants, not a role it is given later, not a direct message,
//! not a narrower approval's old bits, and nothing while it is disabled.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{InstallModuleRequest, ModulePermissionSpec, ModuleRuntimeLimits};
use uuid::Uuid;

use super::harness::{ID, World, world};

const VIEW: i64 = Permissions::VIEW_CHANNEL.bits();
const SEND: i64 = VIEW | Permissions::SEND_MESSAGES.bits();

async fn principal(w: &World) -> UserId {
    w.store
        .installed_module(ID)
        .await
        .unwrap()
        .unwrap()
        .bot_user_id
        .unwrap()
}

async fn create_channel(w: &World, token: &str) -> StatusCode {
    let body = json!({"name": format!("c{}", Uuid::now_v7().simple())});
    w.as_token(token, "POST", "/channels", Some(body)).await.0
}

/// Every role the principal holds and the shared Bots role grant ADMINISTRATOR.
async fn grant_everything_later(w: &World) {
    sqlx::query("UPDATE roles SET permissions = ? WHERE is_bots_role = 1")
        .bind(Permissions::ADMINISTRATOR.bits())
        .execute(&w.pool)
        .await
        .unwrap();
    let role = w
        .store
        .create_role("ops", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    w.store.assign_role(principal(w).await, role).await.unwrap();
}

#[tokio::test]
async fn the_token_does_what_was_approved_and_nothing_everyone_holds_besides() {
    let w = world("slimm-conn-approved", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    let general = w.general().await;
    let message = Uuid::now_v7().to_string();
    let body = json!({"id": message, "content": "hi"});
    let (status, sent) = w
        .as_token(
            &token,
            "POST",
            &format!("/channels/{general}/messages"),
            Some(body),
        )
        .await;
    assert!(status.is_success(), "{status} {sent}");
    let (status, _) = w
        .as_token(
            &token,
            "PUT",
            &format!("/messages/{message}/reactions/%F0%9F%91%8D"),
            None,
        )
        .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "@everyone grants reactions, the admin did not"
    );
    assert_eq!(create_channel(&w, &token).await, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_role_given_later_cannot_widen_the_token() {
    let w = world("slimm-conn-later", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    grant_everything_later(&w).await;
    assert_eq!(create_channel(&w, &token).await, StatusCode::FORBIDDEN);
    let (status, _) = w
        .as_token(&token, "GET", "/space/dock/installed", None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(w.post(&token, &w.general().await).await.is_success());
    let base = w.store.base_permissions(principal(&w).await).await.unwrap();
    assert_eq!(base, Permissions::from_bits(SEND));
}

#[tokio::test]
async fn an_approved_manage_roles_cannot_hand_out_more_than_the_approval() {
    let w = world("slimm-conn-escalate", &["view_channel", "manage_roles"]).await;
    let token = w.installed(VIEW | Permissions::MANAGE_ROLES.bits()).await;
    grant_everything_later(&w).await;
    let wide = json!({"name": "wide", "permissions": Permissions::MANAGE_SERVER.bits()});
    let (status, body) = w.as_token(&token, "POST", "/roles", Some(wide)).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    let narrow = json!({"name": "narrow", "permissions": VIEW});
    let (status, body) = w.as_token(&token, "POST", "/roles", Some(narrow)).await;
    assert!(status.is_success(), "{status} {body}");
}

#[tokio::test]
async fn a_narrower_approval_takes_the_old_bits_away() {
    let w = world("slimm-conn-narrow", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    let general = w.general().await;
    assert!(w.post(&token, &general).await.is_success());
    let (status, body) = w.install(Some(VIEW)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(w.post(&token, &general).await, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_direct_message_needs_the_approval_too() {
    let w = world("slimm-conn-dm", &["view_channel"]).await;
    let token = w.installed(VIEW).await;
    let (status, dm) = w
        .as_token(&token, "POST", &format!("/dms/{}", w.owner.id), None)
        .await;
    let dm = match status.is_success() {
        true => dm["channel_id"].as_str().unwrap().to_owned(),
        false => w
            .store
            .open_dm(w.owner.id, principal(&w).await)
            .await
            .unwrap()
            .id
            .to_string(),
    };
    assert_eq!(w.post(&token, &dm).await, StatusCode::FORBIDDEN);
    let dm_id = slimm_server::ids::ChannelId(dm.parse().unwrap());
    let held = w
        .store
        .permissions_in_channel(principal(&w).await, dm_id)
        .await
        .unwrap();
    assert_eq!(held, Permissions::VIEW_CHANNEL);
    let batched = w
        .store
        .permissions_in_channels(principal(&w).await, &[dm_id])
        .await
        .unwrap();
    assert_eq!(batched[&dm_id], Permissions::VIEW_CHANNEL);
}

#[tokio::test]
async fn a_connector_holds_no_other_module_s_permission() {
    let w = world("slimm-conn-modperm", &["view_channel"]).await;
    w.installed(VIEW).await;
    let spec = [ModulePermissionSpec {
        key: "run",
        name: "Run",
        description: "run it",
    }];
    w.store
        .install_module_with_artifact(
            InstallModuleRequest {
                id: "notes",
                name: "Notes",
                version: "0.1.0",
                artifact_sha256: &"0".repeat(64),
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &spec,
                extension_points: &[],
            },
            b"\0asm",
        )
        .await
        .unwrap();
    let role = w
        .store
        .create_role("runners", Permissions::NONE, false)
        .await
        .unwrap();
    w.store
        .grant_module_permission(role, "notes", "run")
        .await
        .unwrap();
    let principal = principal(&w).await;
    w.store.assign_role(principal, role).await.unwrap();
    assert!(
        !w.store
            .user_has_module_permission(principal, "notes", "run")
            .await
            .unwrap()
    );
    assert!(
        w.store
            .held_module_permissions(principal)
            .await
            .unwrap()
            .is_empty()
    );
    w.store.assign_role(w.owner.id, role).await.unwrap();
    assert!(
        w.store
            .user_has_module_permission(w.owner.id, "notes", "run")
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn a_disabled_connector_holds_nothing() {
    let w = world("slimm-conn-disabled", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    w.set_enabled(false).await;
    let general = w.general().await;
    assert_eq!(w.post(&token, &general).await, StatusCode::FORBIDDEN);
    let general_id = slimm_server::ids::ChannelId(general.parse().unwrap());
    let viewers = w
        .store
        .viewers_among(general_id, &[principal(&w).await])
        .await
        .unwrap();
    assert!(
        viewers.is_empty(),
        "fan-out must not reach a disabled connector"
    );
    let (status, _) = w.as_token(&token, "GET", "/connectors/me", None).await;
    assert_eq!(status, StatusCode::CONFLICT);
    w.set_enabled(true).await;
    assert!(w.post(&token, &general).await.is_success());
}

/// L3: the plain module uninstall never removes a connector's row, and a principal whose
/// row is gone anyway (a race, a hand edit) holds nothing rather than everything.
#[tokio::test]
async fn a_principal_without_its_module_row_holds_nothing() {
    let w = world("slimm-conn-orphan", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    grant_everything_later(&w).await;
    assert!(
        !w.store.uninstall_module(ID).await.unwrap(),
        "the wasm uninstall path left the connector alone"
    );
    assert!(w.store.installed_module(ID).await.unwrap().is_some());
    sqlx::query("DELETE FROM installed_modules WHERE id = ?")
        .bind(ID)
        .execute(&w.pool)
        .await
        .unwrap();
    assert_eq!(create_channel(&w, &token).await, StatusCode::FORBIDDEN);
    let general = w.general().await;
    let body = json!({"id": Uuid::now_v7().to_string(), "content": "still here"});
    let (status, _) = w
        .as_token(
            &token,
            "POST",
            &format!("/channels/{general}/messages"),
            Some(body),
        )
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "no bit survives the row");
}

#[tokio::test]
async fn head_on_a_get_route_meets_the_same_gate_as_get() {
    let w = world("slimm-conn-head", &["send_messages"]).await;
    let token = w.installed(Permissions::SEND_MESSAGES.bits()).await;

    for uri in ["/members", "/channels", "/categories"] {
        let (get, _) = w.as_token(&token, "GET", uri, None).await;
        let (head, _) = w.as_token(&token, "HEAD", uri, None).await;
        assert_eq!(get, StatusCode::FORBIDDEN, "GET {uri}");
        assert_eq!(head, StatusCode::FORBIDDEN, "HEAD {uri}");
    }
}

/// A channel `@everyone` may not view, made by hand so the test owns its overwrite.
async fn private_channel(w: &World) -> slimm_server::ids::ChannelId {
    let channel = w.store.create_channel("private", "text").await.unwrap();
    let everyone: slimm_server::ids::RoleId =
        sqlx::query_scalar("SELECT id FROM roles WHERE is_everyone = 1")
            .fetch_one(&w.pool)
            .await
            .unwrap();
    w.store
        .set_role_overwrite(
            channel.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    channel.id
}

#[tokio::test]
async fn an_administrator_role_given_later_does_not_pass_a_channel_deny() {
    let w = world("slimm-conn-admin-deny", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    let private = private_channel(&w).await;
    grant_everything_later(&w).await;
    let principal = principal(&w).await;

    let held = w
        .store
        .permissions_in_channel(principal, private)
        .await
        .unwrap();
    assert!(!held.contains(Permissions::VIEW_CHANNEL), "{held:?}");
    let batched = w
        .store
        .permissions_in_channels(principal, &[private])
        .await
        .unwrap();
    assert_eq!(batched[&private], Permissions::NONE);
    let viewers = w.store.viewers_among(private, &[principal]).await.unwrap();
    assert!(viewers.is_empty(), "fan-out must not reach the connector");

    let (status, _) = w
        .as_token(
            &token,
            "GET",
            &format!("/channels/{private}/messages"),
            None,
        )
        .await;
    assert!(!status.is_success(), "read the history: {status}");
    assert!(!w.post(&token, &private.to_string()).await.is_success());
    let (status, listed) = w.as_token(&token, "GET", "/channels", None).await;
    assert_eq!(status, StatusCode::OK, "{listed}");
    assert!(!listed.to_string().contains(&private.to_string()));
    assert!(w.post(&token, &w.general().await).await.is_success());
}

#[tokio::test]
async fn a_connector_approved_nothing_cannot_drive_the_link_preview_fetcher() {
    let w = world("slimm-conn-preview", &[]).await;
    let token = w.installed(0).await;
    for uri in [
        "/link-preview?url=https%3A%2F%2Fexample.com%2F",
        "/link-preview/image/abc",
    ] {
        let (status, body) = w.as_token(&token, "GET", uri, None).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{uri}: {body}");
    }
}
