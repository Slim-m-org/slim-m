// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A permission change reaches a member already on the call, whether or not they ever sent a
//! heartbeat: losing View or Connect or being removed ends the call, and Speak and Use Canvas are
//! pushed to the SFU in both directions.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;

use crate::support;
use crate::voice_access_revoked::Call;
use support::app::call_as;
use support::wait::{holds_within, wait_until};

impl Call {
    fn channel_id(&self) -> ChannelId {
        ChannelId(self.channel.parse().unwrap())
    }

    /// Joined at the SFU without ever having sent a heartbeat.
    async fn join_without_heartbeat(&self, user: UserId) {
        self.state
            .voice
            .forget_heartbeat_reporting_removed(user, self.channel_id());
        self.sfu_reports_join(user).await;
    }

    async fn mint_token(&self, token: &str) {
        let uri = format!("/channels/{}/voice/token", self.channel);
        let (status, body) = call_as(&self.router, "POST", &uri, token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    fn grant_updates(&self, user: UserId) -> Vec<Value> {
        self.recorder
            .updates
            .lock()
            .unwrap()
            .iter()
            .filter(|u| u["identity"] == user.to_string().as_str())
            .filter_map(|u| u.get("permission").cloned())
            .collect()
    }

    async fn history(&self) -> Value {
        let uri = "/reports/history?limit=20";
        call_as(&self.router, "GET", uri, &self.admin.token, None)
            .await
            .1
    }

    fn last_publish_grant(&self, user: UserId) -> Option<bool> {
        self.grant_updates(user)
            .last()
            .map(|p| p["canPublish"] == true)
    }
}

#[tokio::test]
async fn losing_connect_ends_the_call_of_a_member_who_never_sent_a_heartbeat() {
    let call = Call::start(true).await;
    call.join_without_heartbeat(call.member.id).await;
    assert!(!call.in_call(call.member.id));
    assert!(!call.removed(call.member.id));

    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::CONNECT,
    )
    .await;

    wait_until("the heartbeat-less member is removed", || {
        call.removed(call.member.id)
    })
    .await;
    assert!(!call.removed(call.admin.id));
}

#[tokio::test]
async fn a_removed_member_is_turned_away_when_the_sfu_lets_them_back_in() {
    let call = Call::start(false).await;
    let uri = format!("/members/{}/removal", call.member.id);
    call.admin("PUT", &uri, Some(json!({}))).await;
    call.recorder.removed.lock().unwrap().clear();

    call.sfu_reports_join(call.member.id).await;

    wait_until("the rejoin is removed again", || {
        call.removed(call.member.id)
    })
    .await;
}

#[tokio::test]
async fn a_removed_member_holds_no_permission_anywhere() {
    let call = Call::start(false).await;
    let uri = format!("/members/{}/removal", call.member.id);
    call.admin("PUT", &uri, Some(json!({}))).await;

    let held = call
        .state
        .store
        .permissions_in_channel(call.member.id, call.channel_id())
        .await
        .unwrap();

    assert_eq!(held, Permissions::NONE);
}

#[tokio::test]
async fn revoking_and_granting_speak_reaches_a_member_already_on_the_call() {
    let call = Call::start(true).await;
    call.mint_token(&call.member.token).await;
    call.sfu_reports_join(call.member.id).await;

    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::SPEAK,
    )
    .await;
    wait_until("publishing is revoked at the SFU", || {
        call.last_publish_grant(call.member.id) == Some(false)
    })
    .await;
    let revoked = call.grant_updates(call.member.id).pop().unwrap();
    assert_eq!(revoked["canSubscribe"], true);
    assert_eq!(revoked["canPublishData"], true, "Use Canvas is untouched");

    call.overwrite(
        "member",
        call.member.id,
        Permissions::SPEAK,
        Permissions::NONE,
    )
    .await;
    wait_until("publishing is granted again", || {
        call.last_publish_grant(call.member.id) == Some(true)
    })
    .await;
}

#[tokio::test]
async fn revoking_use_canvas_stops_data_publishing() {
    let call = Call::start(true).await;
    call.mint_token(&call.member.token).await;

    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::USE_CANVAS,
    )
    .await;

    wait_until("data publishing is revoked", || {
        call.grant_updates(call.member.id)
            .last()
            .is_some_and(|p| p["canPublishData"] == false && p["canPublish"] == true)
    })
    .await;
}

#[tokio::test]
async fn a_change_that_leaves_the_grants_alone_pushes_nothing() {
    let call = Call::start(true).await;
    call.mint_token(&call.member.token).await;
    call.mint_token(&call.admin.token).await;

    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::ADD_REACTIONS,
    )
    .await;

    let pushed = holds_within(Duration::from_millis(400), || {
        !call.grant_updates(call.member.id).is_empty()
    })
    .await;
    assert!(!pushed, "the member's grants did not change");
}

#[tokio::test]
async fn a_kick_writes_a_moderation_entry_and_a_self_kick_does_not() {
    let call = Call::start(false).await;
    let kick = |target: UserId| {
        format!(
            "/channels/{}/voice/participants/{target}/kick",
            call.channel
        )
    };
    let (status, _) = call_as(
        &call.router,
        "POST",
        &kick(call.admin.id),
        &call.admin.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let before = call.history().await;
    assert!(
        before
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e["action"] != "voice_kick")
    );

    let (status, _) = call_as(
        &call.router,
        "POST",
        &kick(call.member.id),
        &call.admin.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let after = call.history().await;
    let entries: Vec<&Value> = after
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["action"] == "voice_kick")
        .collect();
    assert_eq!(entries.len(), 1, "{after}");
    assert_eq!(entries[0]["subject_id"], json!(call.member.id.to_string()));
    assert_eq!(entries[0]["actor_id"], json!(call.admin.id.to_string()));
    assert_eq!(entries[0]["reason"], "lounge");
}
