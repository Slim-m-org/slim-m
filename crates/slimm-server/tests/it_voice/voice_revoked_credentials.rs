// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Revoking the credential a call was joined with ends the call at the SFU, and a join that
//! comes back on that credential's renewed token is turned away.

use axum::Router;
use axum::http::StatusCode;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::UserId;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

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
    admin: Account,
    member: Account,
    channel: String,
    state: AppState,
    _db: support::TestDbGuard,
}

impl Call {
    async fn start() -> Self {
        let recorder = RecordingRoomService::default();
        let url = spawn_sfu(recorder.clone()).await;
        let (store, db) = support::new_store("slimm-voice-revoked-credentials").await;
        let admin = register_account(&store, "admin").await;
        let member = register_account(&store, "member").await;
        let voice = VoiceService::for_test(&url, SFU_KEY, SFU_SECRET);
        let state = support::app::builder(store).voice(voice).build();
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
        Self {
            channel: body["id"].as_str().unwrap().to_owned(),
            recorder,
            router,
            admin,
            member,
            state,
            _db: db,
        }
    }

    fn store(&self) -> &slimm_server::store::Store {
        &self.state.store
    }

    /// The attributes the SFU will report for whoever joins with this caller's token.
    async fn join_attributes(&self, token: &str) -> Value {
        let uri = format!("/channels/{}/voice/token", self.channel);
        let (status, body) = call_as(&self.router, "POST", &uri, token, None).await;
        assert_eq!(status, StatusCode::OK, "voice token: {body}");
        let jwt = body["token"].as_str().unwrap();
        let payload = jwt.split('.').nth(1).unwrap();
        let claims: Value = serde_json::from_slice(&BASE64URL.decode(payload).unwrap()).unwrap();
        claims["attributes"].clone()
    }

    fn room(&self) -> String {
        format!("channel-{}", self.channel)
    }

    /// Seats `user` in the room with `attributes` and has the SFU report the join.
    async fn joins(&self, user: UserId, attributes: &Value) {
        let participant = json!({
            "identity": user.to_string(),
            "sid": format!("PA_{user}"),
            "attributes": attributes,
        });
        self.recorder
            .seat_in_listing(&self.room(), vec![participant.clone()]);
        let body = json!({
            "event": "participant_joined",
            "room": { "name": self.room() },
            "participant": participant,
        });
        let request = webhook_request(body, SFU_KEY, SFU_SECRET);
        let response = self.router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    fn removals(&self, user: UserId) -> usize {
        let room = self.room();
        self.recorder
            .removed
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c["room"] == room.as_str() && c["identity"] == user.to_string().as_str())
            .count()
    }

    async fn post(&self, uri: &str, token: &str, body: Option<Value>) -> (StatusCode, Value) {
        call_as(&self.router, "POST", uri, token, body).await
    }
}

/// Long enough for a detached eviction that was going to run to have run.
async fn settle() {
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
}

#[tokio::test]
async fn signing_out_ends_the_call_that_session_joined() {
    let call = Call::start().await;
    let attributes = call.join_attributes(&call.member.token).await;
    call.joins(call.member.id, &attributes).await;
    settle().await;
    assert_eq!(
        call.removals(call.member.id),
        0,
        "a live session's join stays"
    );

    let (status, _) = call.post("/auth/logout", &call.member.token, None).await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    wait_until("the signed-out device leaves the room", || {
        call.removals(call.member.id) == 1
    })
    .await;
}

#[tokio::test]
async fn a_rejoin_on_a_revoked_sessions_renewed_token_is_turned_away() {
    let call = Call::start().await;
    let attributes = call.join_attributes(&call.member.token).await;
    let (status, _) = call.post("/auth/logout", &call.member.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    call.joins(call.member.id, &attributes).await;

    wait_until("the revoked session's rejoin is removed", || {
        call.removals(call.member.id) >= 1
    })
    .await;
}

#[tokio::test]
async fn spending_a_reset_code_ends_the_call() {
    let call = Call::start().await;
    let attributes = call.join_attributes(&call.member.token).await;
    call.joins(call.member.id, &attributes).await;
    let (code, _) = call
        .store()
        .issue_reset_code(call.admin.id, call.member.id)
        .await
        .unwrap();

    let body = json!({ "code": code, "new_password": "a-brand-new-password" });
    let (status, body) =
        support::app::call(&call.router, "POST", "/auth/reset", None, Some(body)).await;

    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    wait_until("the reset account leaves the room", || {
        call.removals(call.member.id) == 1
    })
    .await;
}

#[tokio::test]
async fn a_call_joined_from_a_device_still_signed_in_stays() {
    let call = Call::start().await;
    let phone = call
        .store()
        .open_session(call.member.id, "phone")
        .await
        .unwrap();
    let attributes = call.join_attributes(&phone.access_token).await;
    call.joins(call.member.id, &attributes).await;

    let (status, _) = call.post("/auth/logout", &call.member.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    settle().await;

    assert_eq!(
        call.removals(call.member.id),
        0,
        "signing one device out leaves another device's call alone"
    );
}

#[tokio::test]
async fn revoking_a_bot_ends_its_call() {
    let call = Call::start().await;
    let (status, created) = call
        .post(
            "/bots",
            &call.admin.token,
            Some(json!({ "username": "helper" })),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let bot_id = UserId(created["bot"]["user_id"].as_str().unwrap().parse().unwrap());
    let attributes = call
        .join_attributes(created["token"].as_str().unwrap())
        .await;
    call.joins(bot_id, &attributes).await;

    let uri = format!("/bots/{bot_id}/revoke");
    let (status, _) = call.post(&uri, &call.admin.token, None).await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    wait_until("the revoked bot leaves the room", || {
        call.removals(bot_id) == 1
    })
    .await;
}
