// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A channel's default notification level (migration 0133): resolved for
//! members with no row of their own in `channel_notification_prefs`, never
//! written into those rows, set by a channel manager at create and edit.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::notifications::NotificationPreference as Level;
use slimm_server::presence::PresenceTracker;
use slimm_server::store::{ChannelPatch, PushRegistration, Store};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_account, request};

struct World {
    store: Store,
    router: Router,
    admin_token: String,
    member_token: String,
    author: UserId,
    member: UserId,
    channel: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, guard) = support::new_store(name).await;
    let admin = register_account(&store, "alice").await;
    let member = register_account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    let device = store
        .open_session(member.id, "phone")
        .await
        .unwrap()
        .device_id;
    let registration = PushRegistration {
        platform: "ios",
        push_token: "bob-token",
        voip_push_token: None,
        push_public_key: &[7u8; 32],
        include_content: Some(false),
        include_content_chosen: true,
    };
    store
        .register_push(member.id, device, registration)
        .await
        .unwrap();
    World {
        router: app(store.clone()),
        store,
        admin_token: admin.token,
        member_token: member.token,
        author: admin.id,
        member: member.id,
        channel,
        _guard: guard,
    }
}

impl World {
    async fn set_default(&self, level: Level) {
        let patch = ChannelPatch {
            default_notification: Some(level),
            ..ChannelPatch::default()
        };
        self.store
            .update_channel_settings(self.channel, patch)
            .await
            .unwrap()
            .unwrap();
    }

    async fn wakes_member(&self, text: &str) -> bool {
        slimm_server::push::message_recipients(
            &self.store,
            self.channel,
            self.author,
            text,
            &PresenceTracker::new(),
        )
        .await
        .unwrap()
        .contains(&self.member)
    }

    async fn own_choice(&self, level: Level) {
        self.store
            .set_channel_notification_preference(self.member, self.channel, level)
            .await
            .unwrap();
    }

    async fn send(&self, method: &str, uri: &str, token: &str, body: Value) -> (StatusCode, Value) {
        let mut req = request(method, uri, Some(token), Some(body.clone()));
        let length = body.to_string().len().into();
        req.headers_mut().insert("content-length", length);
        let response = self.router.clone().oneshot(req).await.unwrap();
        (response.status(), json_body(response).await)
    }
}

#[tokio::test]
async fn each_default_level_decides_what_wakes_a_member_with_no_row() {
    let w = world("slimm-chan-default-levels").await;
    assert!(w.wakes_member("plain").await, "everything is the default");

    w.set_default(Level::Mentions).await;
    assert!(!w.wakes_member("plain").await);
    assert!(w.wakes_member("hey @bob").await);

    w.set_default(Level::Nothing).await;
    assert!(!w.wakes_member("plain").await);
    assert!(!w.wakes_member("hey @bob").await);
}

#[tokio::test]
async fn a_members_own_choice_beats_the_default_in_both_directions() {
    let w = world("slimm-chan-default-override-wins").await;

    w.set_default(Level::Nothing).await;
    w.own_choice(Level::Mentions).await;
    assert!(w.wakes_member("hey @bob").await, "opting in beats nothing");
    assert!(!w.wakes_member("plain").await);

    w.set_default(Level::Mentions).await;
    w.own_choice(Level::Nothing).await;
    assert!(
        !w.wakes_member("hey @bob").await,
        "opting out beats mentions"
    );

    w.set_default(Level::Nothing).await;
    w.own_choice(Level::Everything).await;
    assert!(w.wakes_member("plain").await, "an explicit everything wins");
}

#[tokio::test]
async fn a_default_only_narrows_the_account_preference() {
    let w = world("slimm-chan-default-narrows").await;
    w.store
        .set_notification_preference(w.member, Level::Nothing)
        .await
        .unwrap();
    w.set_default(Level::Mentions).await;
    assert!(
        !w.wakes_member("hey @bob").await,
        "the account's nothing stands"
    );
}

#[tokio::test]
async fn editing_the_default_leaves_members_rows_alone() {
    let w = world("slimm-chan-default-edit-keeps-rows").await;
    w.own_choice(Level::Mentions).await;
    let before = w
        .store
        .list_channel_notification_preferences(w.member)
        .await
        .unwrap();

    let (status, body) = w
        .send(
            "PATCH",
            &format!("/channels/{}", w.channel),
            &w.admin_token,
            json!({ "default_notification": "nothing" }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["default_notification"], "nothing");

    let after = w
        .store
        .list_channel_notification_preferences(w.member)
        .await
        .unwrap();
    assert_eq!(before, after);
}

#[tokio::test]
async fn a_manager_creates_a_channel_with_a_default_and_it_lists_back() {
    let w = world("slimm-chan-default-create").await;
    let (status, created) = w
        .send(
            "POST",
            "/channels",
            &w.admin_token,
            json!({ "name": "quiet", "default_notification": "nothing" }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{created}");
    assert_eq!(created["default_notification"], "nothing");

    let id = ChannelId(created["id"].as_str().unwrap().parse().unwrap());
    let recipients = slimm_server::push::message_recipients(
        &w.store,
        id,
        w.author,
        "hello",
        &PresenceTracker::new(),
    )
    .await
    .unwrap();
    assert!(!recipients.contains(&w.member));

    let listed = w
        .router
        .clone()
        .oneshot(request("GET", "/channels", Some(&w.member_token), None))
        .await
        .unwrap();
    let rows = json_body(listed).await;
    let quiet = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "quiet");
    assert_eq!(quiet.unwrap()["default_notification"], "nothing");
    assert_eq!(rows[0]["default_notification"], "everything");
}

#[tokio::test]
async fn setting_a_default_needs_manage_channels_and_a_known_level() {
    let w = world("slimm-chan-default-permission").await;
    let uri = format!("/channels/{}", w.channel);
    let body = json!({ "default_notification": "mentions" });

    let (status, _) = w.send("PATCH", &uri, &w.member_token, body.clone()).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let create = json!({ "name": "x", "default_notification": "mentions" });
    let (status, _) = w.send("POST", "/channels", &w.member_token, create).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, _) = w
        .send(
            "PATCH",
            &uri,
            &w.admin_token,
            json!({ "default_notification": "loud" }),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = w
        .send(
            "POST",
            "/channels",
            &w.admin_token,
            json!({ "name": "y", "default_notification": "loud" }),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_default_change_is_in_the_admin_audit_log() {
    let w = world("slimm-chan-default-audit").await;
    let (status, _) = w
        .send(
            "PATCH",
            &format!("/channels/{}", w.channel),
            &w.admin_token,
            json!({ "default_notification": "mentions" }),
        )
        .await;
    assert_eq!(status, StatusCode::OK);

    let response = w
        .router
        .clone()
        .oneshot(request(
            "GET",
            "/space/audit-log",
            Some(&w.admin_token),
            None,
        ))
        .await
        .unwrap();
    let log = json_body(response).await;
    let entry = &log.as_array().unwrap()[0];
    assert_eq!(entry["action"], "channel.update");
    assert_eq!(entry["target_id"], w.channel.to_string().as_str());
    assert_eq!(entry["detail"]["fields"], json!(["default_notification"]));
}
