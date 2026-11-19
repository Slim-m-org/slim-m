// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Losing View or Connect ends the call at the SFU straight away, not when the heartbeat goes stale.
//! A LiveKit token cannot be revoked, so the proof is a `RemoveParticipant` reaching a fake room service.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState, evict_who_lost_access, spawn_voice_access_watch};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::voice::VoiceService;

use crate::support;
use support::app::{Account, call_as, register_account};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::livekit_webhook::webhook_request;
use support::wait::wait_until;

const SFU_KEY: &str = "key";
const SFU_SECRET: &str = "a-secret-at-least-32-chars-long!";

struct Call {
    recorder: RecordingRoomService,
    router: Router,
    state: AppState,
    admin: Account,
    member: Account,
    channel: String,
    _db: support::TestDbGuard,
}

impl Call {
    /// An admin and a member, both on a voice channel's call.
    async fn start(watch: bool) -> Self {
        let recorder = RecordingRoomService::default();
        let url = spawn_sfu(recorder.clone()).await;
        let (store, db) = support::new_store("slimm-voice-access-revoked").await;
        let admin = register_account(&store, "admin").await;
        let member = register_account(&store, "member").await;
        let voice = VoiceService::for_test(&url, SFU_KEY, SFU_SECRET);
        let state = support::app::builder(store).voice(voice).build();
        if watch {
            spawn_voice_access_watch(state.clone());
        }
        let router = http::router(state.clone());
        let (status, body) = call_as(
            &router,
            "POST",
            "/channels",
            &admin.token,
            Some(json!({ "name": "lounge", "kind": "voice" })),
        )
        .await;
        assert!(status.is_success(), "create channel: {status} {body}");
        let channel = body["id"].as_str().unwrap().to_owned();
        let call = Self {
            recorder,
            router,
            state,
            admin,
            member,
            channel,
            _db: db,
        };
        for token in [&call.admin.token, &call.member.token] {
            assert_eq!(call.heartbeat(token).await, StatusCode::NO_CONTENT);
        }
        call
    }

    async fn heartbeat(&self, token: &str) -> StatusCode {
        let uri = format!("/channels/{}/voice/heartbeat", self.channel);
        call_as(&self.router, "POST", &uri, token, None).await.0
    }

    async fn admin(&self, method: &str, uri: &str, body: Option<Value>) {
        let (status, body) = call_as(&self.router, method, uri, &self.admin.token, body).await;
        assert!(status.is_success(), "{method} {uri}: {status} {body}");
    }

    async fn overwrite(
        &self,
        kind: &str,
        id: impl std::fmt::Display,
        allow: Permissions,
        deny: Permissions,
    ) {
        let uri = format!("/channels/{}/overwrites/{kind}/{id}", self.channel);
        let body = json!({ "allow": allow.bits(), "deny": deny.bits() });
        self.admin("PUT", &uri, Some(body)).await;
    }

    /// The SFU reporting that `user` joined the call's room.
    async fn sfu_reports_join(&self, user: UserId) {
        use tower::ServiceExt;
        let body = json!({
            "event": "participant_joined",
            "room": { "name": format!("channel-{}", self.channel) },
            "participant": { "identity": user.to_string(), "sid": "PA_join" },
        });
        let request = webhook_request(body, SFU_KEY, SFU_SECRET);
        let response = self.router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    fn removed(&self, user: UserId) -> bool {
        let room = format!("channel-{}", self.channel);
        self.recorder
            .removed
            .lock()
            .unwrap()
            .iter()
            .any(|c| c["room"] == room.as_str() && c["identity"] == user.to_string().as_str())
    }

    fn in_call(&self, user: UserId) -> bool {
        self.state
            .voice
            .has_heartbeat(user, ChannelId(self.channel.parse().unwrap()))
    }
}

#[tokio::test]
async fn a_member_overwrite_denying_connect_ends_their_call_at_once() {
    let call = Call::start(true).await;

    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::CONNECT,
    )
    .await;

    wait_until("the member is removed from the room", || {
        call.removed(call.member.id)
    })
    .await;
    assert!(!call.in_call(call.member.id));
    assert!(
        call.in_call(call.admin.id),
        "the admin kept access and stays"
    );
    assert!(!call.removed(call.admin.id));
}

#[tokio::test]
async fn losing_the_role_that_granted_view_ends_the_call() {
    let call = Call::start(true).await;
    let (status, role) = call_as(
        &call.router,
        "POST",
        "/roles",
        &call.admin.token,
        Some(json!({ "name": "regulars", "permissions": 0 })),
    )
    .await;
    assert!(status.is_success(), "create role: {status} {role}");
    let role = role["id"].as_str().unwrap().to_owned();
    let assignment = format!("/members/{}/roles/{role}", call.member.id);
    call.admin("PUT", &assignment, None).await;
    let (_, roles) = call_as(&call.router, "GET", "/roles", &call.admin.token, None).await;
    let everyone = roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_everyone"] == true)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    call.overwrite("role", &role, Permissions::VIEW_CHANNEL, Permissions::NONE)
        .await;
    call.overwrite(
        "role",
        &everyone,
        Permissions::NONE,
        Permissions::VIEW_CHANNEL,
    )
    .await;
    evict_who_lost_access(&call.state).await;
    assert!(
        !call.removed(call.member.id),
        "the role still grants View, so the member stays"
    );

    call.admin("DELETE", &assignment, None).await;

    wait_until("the member is removed once the role is gone", || {
        call.removed(call.member.id)
    })
    .await;
    assert!(!call.removed(call.admin.id));
}

/// The heartbeat that is refused is itself proof the caller is still in the room.
#[tokio::test]
async fn a_refused_heartbeat_ends_the_call_even_without_the_watch() {
    let call = Call::start(false).await;
    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::CONNECT,
    )
    .await;
    assert!(!call.removed(call.member.id));

    assert_eq!(
        call.heartbeat(&call.member.token).await,
        StatusCode::FORBIDDEN
    );

    assert!(call.removed(call.member.id));
    assert!(!call.in_call(call.member.id));
}

/// In the room on a token, but access went before a first heartbeat landed, so no pass lists them.
#[tokio::test]
async fn a_refused_first_heartbeat_ends_the_call_too() {
    let call = Call::start(false).await;
    let channel = ChannelId(call.channel.parse().unwrap());
    call.state
        .voice
        .forget_heartbeat_reporting_removed(call.member.id, channel);
    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::CONNECT,
    )
    .await;

    assert_eq!(
        call.heartbeat(&call.member.token).await,
        StatusCode::FORBIDDEN
    );

    assert!(call.removed(call.member.id));
}

/// The SFU renews every token it accepts, so one minted before the access went still gets in.
#[tokio::test]
async fn a_join_the_sfu_reports_for_someone_without_connect_is_removed() {
    let call = Call::start(false).await;
    let channel = ChannelId(call.channel.parse().unwrap());
    call.state
        .voice
        .forget_heartbeat_reporting_removed(call.member.id, channel);
    call.overwrite(
        "member",
        call.member.id,
        Permissions::NONE,
        Permissions::CONNECT,
    )
    .await;

    call.sfu_reports_join(call.member.id).await;

    wait_until("the member is removed from the room", || {
        call.removed(call.member.id)
    })
    .await;
}

#[tokio::test]
async fn a_join_the_sfu_reports_for_someone_with_access_stays() {
    let call = Call::start(false).await;

    call.sfu_reports_join(call.member.id).await;

    let removed = support::wait::holds_within(std::time::Duration::from_millis(300), || {
        call.removed(call.member.id)
    })
    .await;
    assert!(!removed, "a member who may be on the call was removed");
}
