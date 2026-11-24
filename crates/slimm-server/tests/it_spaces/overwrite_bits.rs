// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an overwrite may carry and on whom: never ADMINISTRATOR, never a grant a caller writes on
//! themselves, and never anything on a webhook's principal.

use serde_json::json;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::TestApp;

const ADMIN: i64 = Permissions::ADMINISTRATOR.bits();
const SEND: i64 = Permissions::SEND_MESSAGES.bits();
const MANAGE_MESSAGES: i64 = Permissions::MANAGE_MESSAGES.bits();

fn channel_id(raw: &str) -> ChannelId {
    ChannelId(raw.parse().unwrap())
}

#[tokio::test]
async fn an_overwrite_carrying_administrator_is_refused() {
    let app = TestApp::start("slimm-overwrite-admin-bit").await;
    let general = app.general_channel().await;
    let member = app.member.id;
    let uri = format!("/channels/{general}/overwrites/member/{member}");
    for body in [
        json!({"allow": ADMIN, "deny": SEND}),
        json!({"allow": 0, "deny": ADMIN}),
    ] {
        let (status, reply) = app
            .call("PUT", &uri, &app.admin.token, Some(body.clone()))
            .await;
        assert_eq!(status, 400, "{body}: {reply}");
    }
    let batch = json!({"overwrites": [
        {"kind": "member", "id": member.to_string(), "allow": ADMIN, "deny": 0},
    ]});
    let uri = format!("/channels/{general}/overwrites");
    let (status, reply) = app
        .call("PUT", &uri, &app.admin.token, Some(batch.clone()))
        .await;
    assert_eq!(status, 400, "{reply}");

    let (_, category) = app
        .call(
            "POST",
            "/categories",
            &app.admin.token,
            Some(json!({"name": "staff"})),
        )
        .await;
    let uri = format!(
        "/categories/{}/overwrites",
        category["id"].as_str().unwrap()
    );
    let (status, reply) = app.call("PUT", &uri, &app.admin.token, Some(batch)).await;
    assert_eq!(status, 400, "{reply}");
}

#[tokio::test]
async fn an_administrator_bit_already_stored_on_an_overwrite_is_not_reported_as_held() {
    let app = TestApp::start("slimm-overwrite-admin-stored").await;
    let general = channel_id(&app.general_channel().await);
    app.store
        .set_member_overwrite(
            general,
            app.member.id,
            Permissions::ADMINISTRATOR,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    let held = app
        .store
        .permissions_in_channel(app.member.id, general)
        .await
        .unwrap();
    assert!(!held.contains(Permissions::ADMINISTRATOR), "{held:?}");
    assert!(!held.contains(Permissions::SEND_MESSAGES), "{held:?}");
}

/// A moderator who manages roles, below the owner on the ladder.
async fn moderator(app: &TestApp) -> UserId {
    let bits = Permissions::VIEW_CHANNEL
        .union(Permissions::MANAGE_ROLES)
        .union(Permissions::MANAGE_MESSAGES);
    let role = app.create_role("mod", bits.bits()).await;
    let uri = format!("/members/{}/roles/{role}", app.member.id);
    let (status, body) = app.call("PUT", &uri, &app.admin.token, None).await;
    assert_eq!(status, 204, "{body}");
    app.member.id
}

#[tokio::test]
async fn a_caller_cannot_grant_themselves_bits_through_their_own_member_overwrite() {
    let app = TestApp::start("slimm-overwrite-self-grant").await;
    let me = moderator(&app).await;
    let general = app.general_channel().await;
    let uri = format!("/channels/{general}/overwrites/member/{me}");

    let grant = json!({"allow": MANAGE_MESSAGES, "deny": 0});
    let (status, body) = app
        .call("PUT", &uri, &app.member.token, Some(grant.clone()))
        .await;
    assert_eq!(status, 403, "{body}");
    let batch = json!({"overwrites": [
        {"kind": "member", "id": me.to_string(), "allow": MANAGE_MESSAGES, "deny": 0},
    ]});
    let batch_uri = format!("/channels/{general}/overwrites");
    let (status, body) = app
        .call("PUT", &batch_uri, &app.member.token, Some(batch))
        .await;
    assert_eq!(status, 403, "{body}");

    let deny = json!({"allow": 0, "deny": SEND});
    let (status, body) = app.call("PUT", &uri, &app.member.token, Some(deny)).await;
    assert_eq!(status, 204, "narrowing yourself is still allowed: {body}");
    let (status, body) = app.call("PUT", &uri, &app.admin.token, Some(grant)).await;
    assert_eq!(status, 204, "the owner may still grant it: {body}");
}

#[tokio::test]
async fn a_webhook_principal_holds_nothing_whatever_its_member_overwrite_says() {
    let app = TestApp::start("slimm-overwrite-webhook").await;
    let general = channel_id(&app.general_channel().await);
    let minted = app
        .store
        .create_webhook(general, "alerts", app.admin.id)
        .await
        .unwrap();
    let principal = minted.webhook.principal_id;

    let uri = format!("/channels/{general}/overwrites/member/{principal}");
    let grant = json!({"allow": Permissions::MENTION_EVERYONE.bits(), "deny": 0});
    let (status, body) = app.call("PUT", &uri, &app.admin.token, Some(grant)).await;
    assert_eq!(status, 400, "{body}");

    app.store
        .set_member_overwrite(
            general,
            principal,
            Permissions::MENTION_EVERYONE.union(Permissions::VIEW_CHANNEL),
            Permissions::NONE,
        )
        .await
        .unwrap();
    assert!(
        !app.store
            .has_permission(principal, general, Permissions::MENTION_EVERYONE)
            .await
            .unwrap()
    );
    let batched = app
        .store
        .permissions_in_channels(principal, &[general])
        .await
        .unwrap();
    assert_eq!(batched[&general], Permissions::NONE);
    let holders = app
        .store
        .holders_among(general, &[principal], Permissions::MENTION_EVERYONE)
        .await
        .unwrap();
    assert!(holders.is_empty());
}
