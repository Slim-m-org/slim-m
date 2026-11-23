// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector reads its settings, secrets included, with its own token, and
//! nobody else reads the secret: not the admin's settings view, not another
//! bot, not the audit trail.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use super::harness::{ID, world};

const SECRET: &str = "jf-0123456789abcdef";

#[tokio::test]
async fn the_connector_reads_its_settings_and_only_it_reads_the_secret() {
    let w = world("slimm-conn-settings", &["view_channel"]).await;
    let token = w.installed(Permissions::VIEW_CHANNEL.bits()).await;
    let (status, me) = w.as_token(&token, "GET", "/connectors/me", None).await;
    assert_eq!(status, StatusCode::OK, "{me}");
    assert_eq!(me["module_id"], ID);
    assert_eq!(me["settings"]["server_url"], "http://jellyfin:8096");
    assert_eq!(me["settings"]["api_key"], Value::Null);

    let values = json!({"values": {"api_key": SECRET, "server_url": "http://media:8096"}});
    let (status, view) = w
        .as_owner(
            "PUT",
            &format!("/space/dock/modules/{ID}/settings"),
            Some(values),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{view}");
    assert!(!view.to_string().contains(SECRET));
    let (_, view) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}/settings"), None)
        .await;
    assert!(!view.to_string().contains(SECRET));

    let (_, me) = w.as_token(&token, "GET", "/connectors/me", None).await;
    assert_eq!(me["settings"]["api_key"], SECRET);
    assert_eq!(me["settings"]["server_url"], "http://media:8096");
    assert_eq!(me["permissions"], json!(Permissions::VIEW_CHANNEL.bits()));

    let (status, _) = w
        .as_token(&w.owner.token, "GET", "/connectors/me", None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let other = w
        .store
        .create_bot("other", "Other", Permissions::NONE, w.owner.id)
        .await
        .unwrap();
    let (status, _) = w
        .as_token(&other.token, "GET", "/connectors/me", None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (_, listed) = w.as_owner("GET", "/space/dock/installed", None).await;
    assert!(!listed.to_string().contains(SECRET));
    let audit: Vec<String> = sqlx::query_scalar(
        "SELECT COALESCE(action, '') || COALESCE(target_id, '') || COALESCE(detail, '') FROM admin_audit_log
         UNION ALL SELECT COALESCE(action, '') || COALESCE(reason, '') FROM moderation_audit_log",
    )
    .fetch_all(&w.pool)
    .await
    .unwrap();
    assert!(
        !audit.is_empty(),
        "the install and the settings change are audited"
    );
    assert!(
        !audit.concat().contains(SECRET),
        "an audit row holds the secret"
    );
}
