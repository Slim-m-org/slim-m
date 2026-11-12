// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An overwrite on `@everyone` reaches the members it just locked out.
//!
//! `@everyone` has no `member_roles` rows, so resolving "who held the role"
//! from them finds nobody and the event withholds the frame from every
//! ex-viewer; see `live_channel_events.rs` for the member-target case.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, RoleId};
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::ws::{Client, connect, read_frame_skipping_presence_timed, serve, user_ticket};

fn req(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

struct World {
    state: AppState,
    store: Store,
    everyone: RoleId,
    admin: String,
    bob_ws: Client,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let base = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    world_with(base).await
}

async fn world_with(everyone_base: Permissions) -> World {
    let (store, guard) = support::new_store("slimm-live-everyone-overwrite").await;
    let everyone = store
        .create_role("everyone", everyone_base, true)
        .await
        .unwrap();
    let state = support::app::state(store.clone());
    let (admin, _ticket, alice) = user_ticket(&store, "alice").await;
    let (_bob_access, bob_ticket, _bob) = user_ticket(&store, "bob").await;
    let role = store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    store.assign_role(alice, role).await.unwrap();
    let addr = serve(state.clone()).await;
    let bob_ws = connect(addr, &bob_ticket).await;
    World {
        state,
        store,
        everyone,
        admin,
        bob_ws,
        _guard: guard,
    }
}

impl World {
    async fn send(&self, method: &str, uri: &str, body: Option<Value>) -> StatusCode {
        http::router(self.state.clone())
            .oneshot(req(method, uri, &self.admin, body))
            .await
            .unwrap()
            .status()
    }

    fn hide_from_everyone(&self) -> Value {
        json!({ "overwrites": [{
            "kind": "role",
            "id": self.everyone.0.to_string(),
            "allow": 0,
            "deny": Permissions::VIEW_CHANNEL.bits(),
        }] })
    }

    async fn bob_is_told_about(&mut self, channel: ChannelId) {
        let ws = &mut self.bob_ws;
        let told = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let frame = read_frame_skipping_presence_timed(ws).await;
                if frame["type"] == "overwrite.changed" {
                    return frame;
                }
            }
        })
        .await
        .expect("bob must be told his view was revoked");
        assert_eq!(told["channel_id"], channel.to_string());
    }
}

#[tokio::test]
async fn denying_view_to_everyone_reaches_every_former_viewer() {
    let mut w = world().await;
    let channel = w.store.create_channel("general", "text").await.unwrap();

    let uri = format!("/channels/{}/overwrites/role/{}", channel.id, w.everyone.0);
    let status = w
        .send(
            "PUT",
            &uri,
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    w.bob_is_told_about(channel.id).await;
}

#[tokio::test]
async fn a_batch_denying_view_to_everyone_reaches_every_former_viewer() {
    let mut w = world().await;
    let channel = w.store.create_channel("general", "text").await.unwrap();

    let status = w
        .send(
            "PUT",
            &format!("/channels/{}/overwrites", channel.id),
            Some(w.hide_from_everyone()),
        )
        .await;
    assert_eq!(status, StatusCode::OK);

    w.bob_is_told_about(channel.id).await;
}

#[tokio::test]
async fn clearing_an_everyone_grant_reaches_every_former_viewer() {
    let mut w = world_with(Permissions::SEND_MESSAGES).await;
    let channel = w.store.create_channel("secret", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            channel.id,
            w.everyone,
            Permissions::VIEW_CHANNEL,
            Permissions::NONE,
        )
        .await
        .unwrap();

    let uri = format!("/channels/{}/overwrites/role/{}", channel.id, w.everyone.0);
    assert_eq!(w.send("DELETE", &uri, None).await, StatusCode::NO_CONTENT);

    w.bob_is_told_about(channel.id).await;
}

#[tokio::test]
async fn locking_a_category_reaches_the_former_viewers_of_its_synced_channels() {
    let mut w = world().await;
    let created = http::router(w.state.clone())
        .oneshot(req(
            "POST",
            "/categories",
            &w.admin,
            Some(json!({ "name": "staff" })),
        ))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let body = axum::body::to_bytes(created.into_body(), usize::MAX)
        .await
        .unwrap();
    let category = serde_json::from_slice::<Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let response = http::router(w.state.clone())
        .oneshot(req(
            "POST",
            "/channels",
            &w.admin,
            Some(json!({ "name": "plans", "category_id": category })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let channel = serde_json::from_slice::<Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .parse::<uuid::Uuid>()
        .unwrap();

    let status = w
        .send(
            "PUT",
            &format!("/categories/{category}/overwrites"),
            Some(w.hide_from_everyone()),
        )
        .await;
    assert_eq!(status, StatusCode::OK);

    w.bob_is_told_about(ChannelId(channel)).await;
}
