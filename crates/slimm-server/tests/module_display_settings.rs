// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space-wide module display switches: every member reads them on
//! `/version`, only a manager writes them, and a write tells connected clients.

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
    let (store, guard) = new_store("slimm-module-display").await;
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

async fn patch(w: &World, token: &str, body: serde_json::Value) -> StatusCode {
    call(
        &w.router,
        "PATCH",
        "/space/settings",
        Some(token),
        Some(body),
    )
    .await
    .0
}

#[tokio::test]
async fn defaults_are_badges_off_and_sections_on_for_everyone() {
    let w = world().await;
    let (_, version) = call(&w.router, "GET", "/version", Some(&w.member), None).await;
    assert_eq!(version["module_member_badges"], false);
    assert_eq!(version["module_profile_sections"], true);
}

#[tokio::test]
async fn a_member_cannot_write_them() {
    let w = world().await;
    let status = patch(&w, &w.member, json!({"module_member_badges": true})).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (_, version) = call(&w.router, "GET", "/version", Some(&w.member), None).await;
    assert_eq!(version["module_member_badges"], false);
}

#[tokio::test]
async fn a_manager_write_reaches_a_plain_member_and_fans_out() {
    let mut w = world().await;
    let status = patch(
        &w,
        &w.admin,
        json!({"module_member_badges": true, "module_profile_sections": false}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (_, version) = call(&w.router, "GET", "/version", Some(&w.member), None).await;
    assert_eq!(version["module_member_badges"], true);
    assert_eq!(version["module_profile_sections"], false);

    let (_, settings) = call(&w.router, "GET", "/space/settings", Some(&w.admin), None).await;
    assert_eq!(settings["module_member_badges"], true);

    let mut fanned = 0;
    while let Ok(event) = w.events.try_recv() {
        if matches!(event, Event::SpaceSettingsChanged) {
            fanned += 1;
        }
    }
    assert_eq!(fanned, 1);
}

#[tokio::test]
async fn one_switch_leaves_the_other_alone() {
    let w = world().await;
    patch(&w, &w.admin, json!({"module_profile_sections": false})).await;
    let (_, version) = call(&w.router, "GET", "/version", Some(&w.member), None).await;
    assert_eq!(version["module_member_badges"], false);
    assert_eq!(version["module_profile_sections"], false);
}
