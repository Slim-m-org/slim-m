// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The space every nested-category test starts from: gamers is gamer-only,
//! minecraft follows it, and cs2 has its own rows letting only the cs role in.

use std::collections::BTreeMap;

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::http;
use slimm_server::hub::Event;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::sync::broadcast;

use crate::support;
use support::app::call_as;
use support::overwrite_harness::register;

pub(super) struct Member {
    pub token: String,
    pub id: UserId,
}

pub(super) struct World {
    pub app: Router,
    pub store: Store,
    pub events: broadcast::Receiver<Event>,
    pub admin: String,
    pub gamer: Member,
    pub cs: Member,
    pub neither: Member,
    pub everyone: String,
    pub gamer_role: String,
    pub cs_role: String,
    pub gamers: String,
    pub minecraft: String,
    pub cs2: String,
    pub gamers_chat: String,
    pub mc_chat: String,
    pub cs_chat: String,
    _guard: support::TestDbGuard,
}

/// One overwrite entry for a batch body.
pub(super) fn entry(kind: &str, id: &str, allow: Permissions, deny: Permissions) -> Value {
    json!({"kind": kind, "id": id, "allow": allow.bits(), "deny": deny.bits()})
}

pub(super) const VIEW: Permissions = Permissions::VIEW_CHANNEL;
pub(super) const NONE: Permissions = Permissions::NONE;

pub(super) async fn world(prefix: &str) -> World {
    let (store, guard) = support::new_store(prefix).await;
    let state = support::app::state(store.clone());
    let events = state.hub.subscribe();
    let app = http::router(state);
    let (admin, _) = register(&store, "owner").await;
    let gamer = member(&store, "gamer").await;
    let cs = member(&store, "cs").await;
    let neither = member(&store, "neither").await;
    let gamer_role = role(&store, "gamer", &gamer).await;
    let cs_role = role(&store, "cs", &cs).await;
    let everyone = everyone_role(&app, &admin).await;

    let mut w = World {
        app,
        store,
        events,
        admin,
        gamer,
        cs,
        neither,
        everyone,
        gamer_role,
        cs_role,
        gamers: String::new(),
        minecraft: String::new(),
        cs2: String::new(),
        gamers_chat: String::new(),
        mc_chat: String::new(),
        cs_chat: String::new(),
        _guard: guard,
    };
    w.gamers = w.create_category("gamers", None).await;
    let gamers_only = json!([
        entry("role", &w.everyone, NONE, VIEW),
        entry("role", &w.gamer_role, VIEW, NONE),
    ]);
    w.set_overwrites(&w.gamers, gamers_only).await;
    w.minecraft = w.create_category("minecraft", Some(&w.gamers)).await;
    w.cs2 = w.create_category("cs2", Some(&w.gamers)).await;
    let cs_only = json!([
        entry("role", &w.gamer_role, NONE, NONE),
        entry("role", &w.cs_role, VIEW, NONE),
    ]);
    w.set_overwrites(&w.cs2, cs_only).await;
    w.gamers_chat = w.create_channel("gamers-chat", &w.gamers).await;
    w.mc_chat = w.create_channel("mc-chat", &w.minecraft).await;
    w.cs_chat = w.create_channel("cs-chat", &w.cs2).await;
    w.drain();
    w
}

async fn member(store: &Store, name: &str) -> Member {
    let (token, id) = register(store, name).await;
    Member {
        token,
        id: UserId(id.parse().unwrap()),
    }
}

async fn role(store: &Store, name: &str, holder: &Member) -> String {
    let role = store
        .create_role(name, Permissions::NONE, false)
        .await
        .unwrap();
    store.assign_role(holder.id, role).await.unwrap();
    role.0.to_string()
}

async fn everyone_role(app: &Router, admin: &str) -> String {
    let (_, roles) = call_as(app, "GET", "/roles", admin, None).await;
    roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["is_everyone"] == json!(true))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

impl World {
    pub async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        call_as(&self.app, method, uri, token, body).await
    }

    /// [`Self::call`] that must succeed.
    pub async fn ok(&self, method: &str, uri: &str, token: &str, body: Option<Value>) -> Value {
        let (status, value) = self.call(method, uri, token, body).await;
        assert!(status.is_success(), "{method} {uri}: {status} {value}");
        value
    }

    pub async fn create_category(&self, name: &str, parent: Option<&str>) -> String {
        let body = json!({"name": name, "parent_id": parent});
        let created = self
            .ok("POST", "/categories", &self.admin, Some(body))
            .await;
        created["id"].as_str().unwrap().to_owned()
    }

    pub async fn create_channel(&self, name: &str, category: &str) -> String {
        let body = json!({"name": name, "category_id": category});
        let created = self.ok("POST", "/channels", &self.admin, Some(body)).await;
        created["id"].as_str().unwrap().to_owned()
    }

    pub async fn set_overwrites(&self, category: &str, entries: Value) -> Value {
        let uri = format!("/categories/{category}/overwrites");
        let body = json!({"overwrites": entries});
        self.ok("PUT", &uri, &self.admin, Some(body)).await
    }

    pub async fn overwrites(&self, category: &str) -> Value {
        let uri = format!("/categories/{category}/overwrites");
        self.ok("GET", &uri, &self.admin, None).await
    }

    /// The categories `token` is listed, in the order they came.
    pub async fn categories(&self, token: &str) -> Vec<Value> {
        let listed = self.ok("GET", "/categories", token, None).await;
        listed.as_array().unwrap().clone()
    }

    pub async fn category(&self, token: &str, id: &str) -> Option<Value> {
        self.categories(token)
            .await
            .into_iter()
            .find(|c| c["id"] == json!(id))
    }

    pub async fn category_names(&self, token: &str) -> Vec<String> {
        names(&self.categories(token).await)
    }

    pub async fn channel_names(&self, token: &str) -> Vec<String> {
        let listed = self.ok("GET", "/channels", token, None).await;
        names(listed.as_array().unwrap())
    }

    /// Every event published since the last drain.
    pub fn drain(&mut self) -> Vec<Event> {
        let mut out = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            out.push(event);
        }
        out
    }
}

pub(super) fn names(items: &[Value]) -> Vec<String> {
    items
        .iter()
        .map(|item| item["name"].as_str().unwrap().to_owned())
        .collect()
}

pub(super) fn has(names: &[String], name: &str) -> bool {
    names.iter().any(|n| n == name)
}

/// The ids of a listing, in its order.
pub(super) fn ids(listed: &[Value]) -> Vec<String> {
    listed
        .iter()
        .map(|c| c["id"].as_str().unwrap().to_owned())
        .collect()
}

/// The whole arrangement as `PUT /categories/order` takes it, from a listing.
pub(super) fn groups_of(listed: &[Value]) -> Vec<(Value, Vec<String>)> {
    let mut groups: Vec<(Value, Vec<String>)> = vec![(Value::Null, Vec::new())];
    for category in listed {
        let parent = category["parent_id"].clone();
        let id = category["id"].as_str().unwrap().to_owned();
        match groups.iter_mut().find(|(p, _)| *p == parent) {
            Some((_, members)) => members.push(id),
            None => groups.push((parent, vec![id])),
        }
    }
    groups
}

/// A `PUT /categories/order` body from [`groups_of`]-shaped groups.
pub(super) fn order_body(groups: &[(Value, Vec<String>)]) -> Value {
    let groups: Vec<Value> = groups
        .iter()
        .map(|(parent, ids)| json!({"parent_id": parent, "category_ids": ids}))
        .collect();
    json!({"groups": groups})
}

/// How many `CategoryChanged` and `OverwriteChanged` events `events` holds.
pub(super) fn category_events(events: &[Event]) -> (usize, usize) {
    let changed = events
        .iter()
        .filter(|e| matches!(e, Event::CategoryChanged))
        .count();
    let overwrites = events
        .iter()
        .filter(|e| matches!(e, Event::OverwriteChanged { .. }))
        .count();
    (changed, overwrites)
}

/// Each `OverwriteChanged` published since the last drain, by channel id.
pub(super) fn overwrite_events(w: &mut World) -> BTreeMap<String, Vec<UserId>> {
    let mut out = BTreeMap::new();
    for event in w.drain() {
        if let Event::OverwriteChanged {
            channel_id,
            previously_visible_to,
        } = event
        {
            let first = out.insert(channel_id.to_string(), (*previously_visible_to).clone());
            assert!(first.is_none(), "{channel_id} was published twice");
        }
    }
    out
}
