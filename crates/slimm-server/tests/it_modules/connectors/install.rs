// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing a connector from the Dock: what the admin is shown, what they
//! must approve, the token shown once, and uninstall taking the token away.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;

use super::harness::{ID, manifest, world};

const SEND: i64 = Permissions::VIEW_CHANNEL.bits() | Permissions::SEND_MESSAGES.bits();

#[tokio::test]
async fn the_dock_shows_what_a_connector_asks_for() {
    let w = world("slimm-conn-shown", &["view_channel", "send_messages"]).await;
    let (status, shown) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
        .await;
    assert_eq!(status, StatusCode::OK, "{shown}");
    assert_eq!(shown["provider"], "connector");
    assert_eq!(shown["connector"]["permissions"], json!(SEND));
    assert_eq!(shown["addon_api"], 7);
    assert_eq!(shown["settings"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn the_token_is_shown_once_and_never_listed() {
    let w = world("slimm-conn-once", &["view_channel", "send_messages"]).await;
    let (status, installed) = w.install(Some(SEND)).await;
    assert_eq!(status, StatusCode::OK, "{installed}");
    let token = installed["connector_token"].as_str().unwrap().to_owned();
    assert!(token.starts_with("slimbot_"));
    assert_eq!(installed["provider"], "connector");
    assert_eq!(installed["connector_permissions"], json!(SEND));

    let (_, listed) = w.as_owner("GET", "/space/dock/installed", None).await;
    assert!(!listed.to_string().contains(&token));
    assert_eq!(listed[0]["connector_permissions"], json!(SEND));
    assert!(listed[0].get("connector_token").is_none());

    let (status, again) = w.install(Some(SEND)).await;
    assert_eq!(status, StatusCode::OK, "{again}");
    assert!(
        again.get("connector_token").is_none(),
        "an update keeps the token: {again}"
    );
    let (_, bots) = w.as_owner("GET", "/bots", None).await;
    assert!(!bots.to_string().contains(&token));
}

#[tokio::test]
async fn an_app_that_cannot_show_the_ask_cannot_install_a_connector() {
    let w = world("slimm-conn-oldapp", &["view_channel"]).await;
    let (status, body) = w.install(None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(body.to_string().contains("update the app"));
    assert!(w.store.installed_module(ID).await.unwrap().is_none());
}

#[tokio::test]
async fn an_approval_must_stay_inside_the_ask() {
    let w = world("slimm-conn-subset", &["view_channel"]).await;
    let (status, body) = w.install(Some(SEND)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    let (status, body) = w.install(Some(Permissions::VIEW_CHANNEL.bits())).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn a_connector_manifest_cannot_also_declare_wasm_powers() {
    let w = world("slimm-conn-wasm", &["view_channel"]).await;
    let mut doc = manifest(&["view_channel"]);
    doc["capabilities"] = json!(["kv.store"]);
    *w.served.lock().unwrap() = doc;
    let (status, body) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
        .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert!(body.to_string().contains("may not declare capabilities"));
}

#[tokio::test]
async fn uninstall_revokes_the_token_and_the_principal() {
    let w = world("slimm-conn-uninstall", &["view_channel", "send_messages"]).await;
    let token = w.installed(SEND).await;
    let principal = w
        .store
        .installed_module(ID)
        .await
        .unwrap()
        .unwrap()
        .bot_user_id
        .unwrap();
    assert_eq!(
        w.as_token(&token, "GET", "/connectors/me", None).await.0,
        StatusCode::OK
    );

    let (status, body) = w
        .as_owner("DELETE", &format!("/space/dock/modules/{ID}/install"), None)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert_eq!(
        w.as_token(&token, "GET", "/connectors/me", None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        w.post(&token, &w.general().await).await,
        StatusCode::UNAUTHORIZED
    );
    let roles: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM member_roles WHERE user_id = ?")
        .bind(principal)
        .fetch_one(&w.pool)
        .await
        .unwrap();
    assert_eq!(roles, 0);

    let (status, again) = w.install(Some(SEND)).await;
    assert_eq!(status, StatusCode::OK, "{again}");
    let fresh = again["connector_token"]
        .as_str()
        .expect("a reinstall mints a new principal");
    assert_ne!(fresh, token);
}

#[tokio::test]
async fn a_reissued_token_replaces_the_old_one() {
    let w = world("slimm-conn-reissue", &["view_channel"]).await;
    let old = w.installed(Permissions::VIEW_CHANNEL.bits()).await;
    let (status, body) = w
        .as_owner(
            "POST",
            &format!("/space/dock/modules/{ID}/connector-token"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let new = body["token"].as_str().unwrap();
    assert_eq!(
        w.as_token(&old, "GET", "/connectors/me", None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        w.as_token(new, "GET", "/connectors/me", None).await.0,
        StatusCode::OK
    );
    let (status, _) = w
        .as_token(
            new,
            "POST",
            &format!("/space/dock/modules/{ID}/connector-token"),
            None,
        )
        .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "a connector cannot re-key itself"
    );
}

#[tokio::test]
async fn a_wasm_module_and_a_connector_cannot_replace_each_other() {
    let w = world("slimm-conn-swap", &["view_channel"]).await;
    w.installed(Permissions::VIEW_CHANNEL.bits()).await;
    let wasm = json!({
        "schema": 1, "id": ID, "name": "Jellyfin", "version": "0.2.0", "summary": "s",
        "artifact": {"kind": "wasm", "path": "m.wasm", "sha256": "0".repeat(64)},
        "runtime": {"backend": "wasm"}
    });
    *w.served.lock().unwrap() = wasm;
    let (status, shown) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
        .await;
    assert_eq!(status, StatusCode::OK, "{shown}");
    let body = json!({"version": "0.2.0", "reviewed_digest": shown["review_digest"]});
    let (status, body) = w
        .as_owner(
            "POST",
            &format!("/space/dock/modules/{ID}/install"),
            Some(body),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    let module = w.store.installed_module(ID).await.unwrap().unwrap();
    assert!(module.is_connector());
    assert_eq!(module.version, "0.1.0");
}
