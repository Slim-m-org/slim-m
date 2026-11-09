// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A change to anything `/version` shows about the Space reaches every
//! connected member as `Event::SpaceSettingsChanged`, so their clients re-read
//! it: the name, the description and the icon, not only the module switches.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::hub::{Event, Hub};
use tokio::sync::broadcast::Receiver;
use tower::ServiceExt;

mod support;

use support::app::{call_as, register_token_id as register};
use support::images::small_png;

struct World {
    router: Router,
    events: Receiver<Event>,
    admin: String,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (store, guard) = support::new_store("slimm-space-settings-event").await;
    let hub = Hub::new();
    let events = hub.subscribe();
    let (admin, _) = register(&store, "root").await;
    World {
        router: support::app::builder(store).hub(hub).router(),
        events,
        admin,
        _guard: guard,
    }
}

impl World {
    async fn patch(&self, body: serde_json::Value) {
        let (status, _) = call_as(
            &self.router,
            "PATCH",
            "/space/settings",
            &self.admin,
            Some(body),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    async fn icon(&self, method: &str, bytes: Vec<u8>) {
        let request = Request::builder()
            .method(method)
            .uri("/space/icon")
            .header("authorization", format!("Bearer {}", self.admin))
            .header("content-type", "application/octet-stream")
            .body(Body::from(bytes))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        assert!(response.status().is_success(), "{}", response.status());
    }

    fn published(&mut self) -> Vec<Event> {
        std::iter::from_fn(|| self.events.try_recv().ok()).collect()
    }
}

fn settings_changed(events: &[Event]) -> usize {
    events
        .iter()
        .filter(|event| matches!(event, Event::SpaceSettingsChanged))
        .count()
}

#[tokio::test]
async fn renaming_the_space_publishes_one_settings_event() {
    let mut w = world().await;
    w.patch(json!({"name": "Nick's place"})).await;

    assert_eq!(settings_changed(&w.published()), 1);
}

#[tokio::test]
async fn a_description_a_noise_default_and_the_invite_switch_each_publish() {
    let mut w = world().await;
    for body in [
        json!({"description": "a small place"}),
        json!({"strong_noise_suppression": true}),
        json!({"members_can_invite": true}),
        json!({"hide_bots_in_member_list": true}),
        json!({"module_member_badges": true}),
    ] {
        w.patch(body.clone()).await;
        assert_eq!(settings_changed(&w.published()), 1, "{body}");
    }
}

#[tokio::test]
async fn a_setting_version_does_not_show_publishes_nothing() {
    let mut w = world().await;
    w.patch(json!({"join_policy": "open"})).await;

    assert_eq!(settings_changed(&w.published()), 0);
}

#[tokio::test]
async fn setting_and_clearing_the_icon_each_publish() {
    let mut w = world().await;
    w.icon("POST", small_png()).await;
    assert_eq!(settings_changed(&w.published()), 1);

    w.icon("DELETE", Vec::new()).await;
    assert_eq!(settings_changed(&w.published()), 1);
}
