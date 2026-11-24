// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Space settings, themes and uploads: what a padded, unauthorised or half-failing request leaves behind.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::app::{app, call_as, register_token_id as register};

const PNG: [u8; 57] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x44, 0x41, 0x54, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0x00, 0x00, 0x00, 0x00,
];

fn theme(name: &str, author: &str) -> Value {
    json!({
        "format": "slimm-theme", "version": 1, "name": name, "author": author,
        "base": "dark", "brightness": "dark",
        "tokens": {
            "surfaceSunken": "#0B0D10", "surfaceBase": "#12151A", "surfaceRaised": "#1C2027",
            "borderSubtle": "#2A2F38", "borderStrong": "#7C8696",
            "textPrimary": "#EEF1F5", "textSecondary": "#A9B2BF", "textDisabled": "#5E6672",
            "accent": "#7FB2FF", "accentFill": "#7FB2FF", "accentOn": "#06101F",
            "accentSoft": "#1B2A44", "accentRing": "#407FB2FF", "focusRing": "#7FB2FF",
            "dangerText": "#F0958A", "dangerBorder": "#D0675B",
            "warnText": "#E0B050", "warnSoft": "#1AE0B050", "stripe": "#12A9B2BF"
        }
    })
}

async fn upload(router: &Router, uri: &str, token: &str, bytes: Vec<u8>) -> StatusCode {
    let request = Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/octet-stream")
        .body(Body::from(bytes))
        .unwrap();
    router.clone().oneshot(request).await.unwrap().status()
}

#[tokio::test]
async fn a_padded_theme_name_and_author_are_stored_trimmed() {
    let (store, _guard) = support::new_store("slimm-theme-padded").await;
    let router = app(store.clone());
    let (_admin, _) = register(&store, "admin").await;
    let (member, _) = register(&store, "member").await;
    let padded = theme(&format!("Dusk{}", " ".repeat(20_000)), &" ".repeat(20_000));

    let (status, created) = call_as(&router, "POST", "/space/themes", &member, Some(padded)).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    assert_eq!(created["theme"]["name"], "Dusk");
    assert_eq!(created["theme"]["author"], "");
    assert!(created["theme"].to_string().len() < 4096);
}

#[tokio::test]
async fn a_timed_out_member_cannot_publish_a_theme() {
    let (store, _guard) = support::new_store("slimm-theme-timeout").await;
    let router = app(store.clone());
    let (admin, _) = register(&store, "admin").await;
    let (member, member_id) = register(&store, "member").await;
    let uri = format!("/members/{member_id}/timeout");
    let (status, _) = call_as(
        &router,
        "PUT",
        &uri,
        &admin,
        Some(json!({"duration_seconds": 300})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call_as(
        &router,
        "POST",
        "/space/themes",
        &member,
        Some(theme("Dusk", "me")),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, listed) = call_as(&router, "GET", "/space/themes", &admin, None).await;
    assert!(listed["themes"].as_array().unwrap().is_empty());
}

async fn manager_and_private_welcome(
    prefix: &str,
) -> (Router, support::TestDbGuard, String, String, String) {
    let (store, guard) = support::new_store(prefix).await;
    let router = app(store.clone());
    let (root, _) = register(&store, "root").await;
    let (_, hidden) = call_as(
        &router,
        "POST",
        "/channels",
        &root,
        Some(json!({"name": "staff", "restricted": true})),
    )
    .await;
    let hidden = hidden["id"].as_str().unwrap().to_owned();
    let role = json!({"name": "managers", "permissions": Permissions::MANAGE_SERVER.bits()});
    let (_, role) = call_as(&router, "POST", "/roles", &root, Some(role)).await;
    let (manager, manager_id) = register(&store, "manager").await;
    let grant = format!(
        "/members/{manager_id}/roles/{}",
        role["id"].as_str().unwrap()
    );
    let (status, _) = call_as(&router, "PUT", &grant, &root, None).await;
    assert!(status.is_success());
    let body = json!({"welcome_enabled": true, "welcome_channel_id": hidden, "welcome_message": "root says hi"});
    let (status, _) = call_as(&router, "PATCH", "/space/settings", &root, Some(body)).await;
    assert_eq!(status, StatusCode::OK);
    (router, guard, root, manager, hidden)
}

#[tokio::test]
async fn changing_only_the_welcome_text_needs_access_to_the_stored_channel() {
    let (router, _guard, root, manager, _hidden) =
        manager_and_private_welcome("slimm-welcome-text").await;
    for body in [
        json!({"welcome_message": "changed"}),
        json!({"welcome_enabled": true}),
    ] {
        let (status, _) = call_as(&router, "PATCH", "/space/settings", &manager, Some(body)).await;
        assert!(status.is_client_error(), "{status}");
    }
    let (_, settings) = call_as(&router, "GET", "/space/settings", &root, None).await;
    assert_eq!(settings["welcome_message"], "root says hi");
}

#[tokio::test]
async fn a_username_the_mention_grammar_would_cut_does_not_mention_another_member() {
    let (store, _guard) = support::new_store("slimm-welcome-dot").await;
    let router = app(store.clone());
    let (root, _) = register(&store, "root").await;
    let (_sam, _) = register(&store, "sam").await;
    let (_, channels) = call_as(&router, "GET", "/channels", &root, None).await;
    let general = channels[0]["id"].as_str().unwrap().to_owned();
    let body = json!({"welcome_enabled": true, "welcome_channel_id": general, "welcome_message": "hi {user}"});
    let (status, _) = call_as(&router, "PATCH", "/space/settings", &root, Some(body)).await;
    assert_eq!(status, StatusCode::OK);

    let (_, invite) = call_as(&router, "POST", "/invites", &root, Some(json!({}))).await;
    let code = invite["code"].as_str().unwrap();
    let newcomer = store.create_account("sam.", "Sam Dot", "x").await.unwrap();
    let token = store
        .open_session(newcomer.id, "cli")
        .await
        .unwrap()
        .access_token;
    let redeem = format!("/invites/{code}/redeem");
    let (status, _) = call_as(&router, "POST", &redeem, &token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, posted) = call_as(
        &router,
        "GET",
        &format!("/channels/{general}/messages"),
        &root,
        None,
    )
    .await;
    let content = posted[0]["content"].as_str().unwrap();
    assert_eq!(content, "hi Sam Dot");
}

#[tokio::test]
async fn a_failing_setting_leaves_none_of_the_patch_applied() {
    let (store, pool, _guard) = support::new_store_with_pool("slimm-settings-atomic").await;
    let router = app(store.clone());
    let (root, _) = register(&store, "root").await;
    sqlx::query(
        "CREATE TRIGGER refuse_description BEFORE UPDATE ON space_settings
         WHEN NEW.description = 'boom' BEGIN SELECT RAISE(ABORT, 'refused'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (_, before) = call_as(&router, "GET", "/space/settings", &root, None).await;

    let body = json!({"name": "Renamed", "hide_bots_in_member_list": true, "description": "boom"});
    let (status, _) = call_as(&router, "PATCH", "/space/settings", &root, Some(body)).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    let (_, after) = call_as(&router, "GET", "/space/settings", &root, None).await;
    assert_eq!(after, before);
}

#[tokio::test]
async fn a_member_is_refused_before_a_space_upload_body_is_read() {
    let (store, _guard) = support::new_store("slimm-upload-order").await;
    let router = app(store.clone());
    let (_admin, _) = register(&store, "admin").await;
    let (member, _) = register(&store, "member").await;
    for (uri, size) in [
        ("/space/icon", 600 * 1024),
        ("/space/banner", 5 * 1024 * 1024),
    ] {
        let status = upload(&router, uri, &member, vec![0; size]).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{uri}");
    }
}

#[tokio::test]
async fn a_replaced_icon_and_banner_are_revalidated_not_cached_forever() {
    let (store, _guard) = support::new_store("slimm-icon-cache").await;
    let router = app(store.clone());
    let (admin, _) = register(&store, "admin").await;
    for uri in ["/space/icon", "/space/banner"] {
        assert_eq!(
            upload(&router, uri, &admin, PNG.to_vec()).await,
            StatusCode::OK
        );
        let request = Request::builder()
            .uri(uri)
            .header("authorization", format!("Bearer {admin}"))
            .body(Body::empty())
            .unwrap();
        let response = router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cache = response.headers()["cache-control"]
            .to_str()
            .unwrap()
            .to_owned();
        assert!(!cache.contains("immutable"), "{uri}: {cache}");
        assert!(cache.contains("no-cache"), "{uri}: {cache}");
    }
}
