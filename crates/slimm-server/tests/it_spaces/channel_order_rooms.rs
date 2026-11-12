// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Temporary voice rooms are not real channels: they do not count toward the
//! last-channel guard, and a stale rail arrangement is not refused over one.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::{Channel, DeleteChannelError, Store};
use tower::ServiceExt;

use crate::support;
use support::app::{app, json_body, register_token as register, request};

struct World {
    store: Store,
    app: Router,
    token: String,
    lobby: Channel,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-channel-order-rooms").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::MANAGE_CHANNELS),
            true,
        )
        .await
        .unwrap();
    let lobby = store.create_channel("lobby", "voice").await.unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    World {
        store,
        app,
        token,
        lobby,
        _guard: guard,
    }
}

impl World {
    async fn room(&self, owner: &str) -> Channel {
        let owner = self.store.create_user(owner, owner).await.unwrap();
        self.store
            .create_voice_room(&self.lobby, owner.id, "a room")
            .await
            .unwrap()
    }

    async fn listed(&self) -> Vec<Value> {
        let response = self
            .app
            .clone()
            .oneshot(request("GET", "/channels", Some(&self.token), None))
            .await
            .unwrap();
        json_body(response).await.as_array().unwrap().clone()
    }

    async fn put_order(&self, ids: &[String]) -> StatusCode {
        let body = json!({ "channel_ids": ids });
        self.app
            .clone()
            .oneshot(request(
                "PUT",
                "/channels/order",
                Some(&self.token),
                Some(body),
            ))
            .await
            .unwrap()
            .status()
    }
}

fn id_of(channel: &Value) -> String {
    channel["id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_room_does_not_keep_the_last_real_channel_alive() {
    let w = world().await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    w.room("bob").await;
    assert!(w.store.delete_channel(w.lobby.id).await.unwrap());

    let refused = w.store.delete_channel(general.id).await;

    assert!(matches!(refused, Err(DeleteChannelError::LastChannel)));
}

#[tokio::test]
async fn a_room_can_still_be_removed_beside_the_last_real_channel() {
    let w = world().await;
    w.store.create_channel("general", "text").await.unwrap();
    let room = w.room("bob").await;
    assert!(w.store.delete_channel(w.lobby.id).await.unwrap());

    assert!(w.store.delete_channel(room.id).await.unwrap());
}

#[tokio::test]
async fn an_arrangement_naming_a_room_that_has_since_gone_still_applies() {
    let w = world().await;
    w.store.create_channel("general", "text").await.unwrap();
    let room = w.room("bob").await;
    let mut ids: Vec<String> = w.listed().await.iter().map(id_of).collect();
    ids.reverse();
    assert!(ids.contains(&room.id.to_string()));
    assert!(w.store.delete_channel(room.id).await.unwrap());

    assert_eq!(w.put_order(&ids).await, StatusCode::OK);
}

#[tokio::test]
async fn an_arrangement_made_before_a_room_appeared_still_applies() {
    let w = world().await;
    w.store.create_channel("general", "text").await.unwrap();
    let mut ids: Vec<String> = w.listed().await.iter().map(id_of).collect();
    ids.reverse();
    w.room("bob").await;

    assert_eq!(w.put_order(&ids).await, StatusCode::OK);
}

#[tokio::test]
async fn a_room_stays_beside_its_lobby_when_the_lobby_is_moved() {
    let w = world().await;
    let general = w.store.create_channel("general", "text").await.unwrap();
    let last = w.store.create_channel("last", "text").await.unwrap();
    let room = w.room("bob").await;
    let order = [general.id, last.id, w.lobby.id].map(|id| id.to_string());

    assert_eq!(w.put_order(&order).await, StatusCode::OK);

    let listed = w.listed().await;
    let names: Vec<&str> = listed.iter().map(|c| c["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["general", "last", "lobby", "a room"]);
    assert_eq!(id_of(&listed[3]), room.id.to_string());
}
