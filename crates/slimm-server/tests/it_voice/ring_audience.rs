// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who a DM call ring actually reaches over the socket: the callees, never the caller.

use axum::Router;
use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::http;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

use crate::support;
use support::app::{json_body, request_bare as request};
use support::ws::{
    Client, assert_no_frame_of_type, connect, read_frame_of_type, serve, user_ticket,
};

pub(crate) struct Rig {
    pub app: Router,
    pub store: Store,
    pub state: slimm_server::http::AppState,
    pub addr: std::net::SocketAddr,
    _guard: support::TestDbGuard,
}

pub(crate) struct Person {
    pub id: String,
    pub token: String,
    pub ws: Client,
}

pub(crate) async fn rig(prefix: &str) -> Rig {
    let (store, guard) = support::new_store(prefix).await;
    let voice = VoiceService::for_test(
        "wss://livekit.example.com",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    let state = support::app::builder(store.clone()).voice(voice).build();
    let addr = serve(state.clone()).await;
    Rig {
        app: http::router(state.clone()),
        store,
        state,
        addr,
        _guard: guard,
    }
}

impl Rig {
    pub async fn person(&self, name: &str) -> Person {
        let (token, ticket, id) = user_ticket(&self.store, name).await;
        let ws = connect(self.addr, &ticket).await;
        Person {
            id: id.to_string(),
            token,
            ws,
        }
    }

    pub async fn post(&self, uri: &str, who: &Person) -> axum::response::Response {
        self.app
            .clone()
            .oneshot(request("POST", uri, Some(&who.token)))
            .await
            .unwrap()
    }

    pub async fn open_dm(&self, from: &Person, to: &Person) -> String {
        let response = self.post(&format!("/dms/{}", to.id), from).await;
        assert_eq!(response.status(), StatusCode::OK);
        json_body(response).await["channel_id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    pub async fn heartbeat(&self, channel: &str, who: &Person) {
        let response = self
            .post(&format!("/channels/{channel}/voice/heartbeat"), who)
            .await;
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    pub async fn ring(&self, channel: &str, who: &Person) -> Value {
        let response = self
            .post(&format!("/channels/{channel}/voice/ring"), who)
            .await;
        assert_eq!(response.status(), StatusCode::OK);
        json_body(response).await
    }
}

#[tokio::test]
async fn the_caller_is_not_sent_its_own_ring() {
    let rig = rig("slimm-ring-audience-own").await;
    let mut alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    let frame = read_frame_of_type(&mut bob.ws, "call.ringing").await;
    assert_eq!(frame["ring_id"], started["ring_id"]);
    assert_eq!(frame["caller_id"], alice.id);
    assert_no_frame_of_type(&mut alice.ws, "call.ringing").await;
}

#[tokio::test]
async fn nobody_is_rung_until_the_caller_is_in_the_call() {
    let rig = rig("slimm-ring-audience-empty-room").await;
    let alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;

    let started = rig.ring(&channel, &alice).await;
    assert_no_frame_of_type(&mut bob.ws, "call.ringing").await;

    rig.heartbeat(&channel, &alice).await;
    let frame = read_frame_of_type(&mut bob.ws, "call.ringing").await;
    assert_eq!(frame["ring_id"], started["ring_id"]);
}

#[tokio::test]
async fn someone_already_in_the_call_is_not_rung() {
    let rig = rig("slimm-ring-audience-present").await;
    let mut alice = rig.person("alice").await;
    let mut bob = rig.person("bob").await;
    let channel = rig.open_dm(&alice, &bob).await;
    rig.heartbeat(&channel, &bob).await;
    rig.heartbeat(&channel, &alice).await;

    let started = rig.ring(&channel, &alice).await;

    assert_no_frame_of_type(&mut bob.ws, "call.ringing").await;
    let ended = read_frame_of_type(&mut alice.ws, "call.ring_ended").await;
    assert_eq!(ended["ring_id"], started["ring_id"]);
    assert_eq!(ended["outcome"], "answered");
}
