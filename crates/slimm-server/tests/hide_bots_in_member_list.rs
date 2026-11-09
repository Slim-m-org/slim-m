// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space-wide switch that takes bots out of the member list: every member
//! reads it on `/version`, only a manager writes it, and a write tells
//! connected clients.

use axum::Router;
use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http;
use slimm_server::hub::Event;
use tokio::sync::broadcast;

mod support;

use support::app::call;
use support::overwrite_harness::{new_store, register};

struct World {
    router: Router,
    events: broadcast::Receiver<Event>,
    admin: String,
    member: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = new_store("slimm-hide-bots").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    let state = support::app::state(store);
    let events = state.hub.subscribe();
    World {
        router: http::router(state),
        events,
        admin,
        member,
        _guard: guard,
    }
}

impl World {
    async fn patch(&self, token: &str, body: serde_json::Value) -> StatusCode {
        call(
            &self.router,
            "PATCH",
            "/space/settings",
            Some(token),
            Some(body),
        )
        .await
        .0
    }

    async fn hidden_on_version(&self) -> serde_json::Value {
        let (_, version) = call(&self.router, "GET", "/version", Some(&self.member), None).await;
        version["hide_bots_in_member_list"].clone()
    }

    async fn hidden_in_settings(&self) -> serde_json::Value {
        let (_, settings) = call(
            &self.router,
            "GET",
            "/space/settings",
            Some(&self.admin),
            None,
        )
        .await;
        settings["hide_bots_in_member_list"].clone()
    }
}

#[tokio::test]
async fn bots_are_listed_until_a_manager_says_otherwise() {
    let w = world().await;
    assert_eq!(w.hidden_on_version().await, false);
    assert_eq!(w.hidden_in_settings().await, false);
}

#[tokio::test]
async fn a_member_cannot_write_it() {
    let w = world().await;
    let status = w
        .patch(&w.member, json!({"hide_bots_in_member_list": true}))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(w.hidden_on_version().await, false);
}

#[tokio::test]
async fn a_manager_write_round_trips_and_reaches_a_plain_member() {
    let w = world().await;
    let (status, body) = call(
        &w.router,
        "PATCH",
        "/space/settings",
        Some(&w.admin),
        Some(json!({"hide_bots_in_member_list": true})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["hide_bots_in_member_list"], true);
    assert_eq!(w.hidden_on_version().await, true);
    assert_eq!(w.hidden_in_settings().await, true);

    let status = w
        .patch(&w.admin, json!({"hide_bots_in_member_list": false}))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(w.hidden_on_version().await, false);
}

#[tokio::test]
async fn a_write_fans_out_once_and_leaves_the_other_switches_alone() {
    let mut w = world().await;
    w.patch(&w.admin, json!({"hide_bots_in_member_list": true}))
        .await;

    let mut fanned = 0;
    while let Ok(event) = w.events.try_recv() {
        if matches!(event, Event::SpaceSettingsChanged) {
            fanned += 1;
        }
    }
    assert_eq!(fanned, 1);

    let (_, version) = call(&w.router, "GET", "/version", Some(&w.member), None).await;
    assert_eq!(version["members_can_invite"], false);
    assert_eq!(version["module_member_badges"], false);
}
