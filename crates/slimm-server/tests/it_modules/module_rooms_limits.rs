// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared room state (decision 0131): one member cannot use up a module's
//! rooms, and an input waiting for its turn does not outlive the module being turned off.

use std::time::Duration;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::support;
use support::room_world::{RoomWorld, canned_room_wasm, room_world};
use support::wasm_fixtures::busy_canned_wasm;

fn counter_state() -> Value {
    json!({ "$slim": "room/1", "state": { "n": 1 } })
}

#[tokio::test]
async fn one_member_cannot_fill_a_modules_rooms_for_everyone() {
    let r = room_world(
        "slimm-rooms-opener",
        "counter",
        canned_room_wasm(&counter_state()),
    )
    .await;
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    let mut channels = Vec::new();
    for n in 0..6 {
        let name = format!("room-{n}");
        channels.push(r.w.store.create_channel(&name, "text").await.unwrap().id);
    }
    for channel in &channels[..4] {
        assert_eq!(r.input_in(&ava, *channel, "go").await.0, StatusCode::OK);
    }
    let (status, _) = r.input_in(&ava, channels[4], "go").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    let (status, _) = r.input_in(&ben, channels[4], "go").await;
    assert_eq!(status, StatusCode::OK, "another member still opens a room");
    let (status, _) = r.input_in(&ava, channels[0], "again").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "a room the member holds still takes input"
    );
}

#[tokio::test]
async fn an_input_waiting_when_the_module_is_turned_off_does_not_run_it() {
    let busy = busy_canned_wasm(1_500_000, &counter_state());
    let r = room_world("slimm-rooms-queued-off", "counter", busy).await;
    let admins =
        r.w.store
            .create_role("admins", Permissions::MANAGE_SERVER, false)
            .await
            .unwrap();
    r.w.store.assign_role(r.w.user.id, admins).await.unwrap();
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    r.join_call(&ava);
    r.join_call(&ben);
    let first = r.input(&ava, "1");
    let second = async {
        tokio::time::sleep(Duration::from_millis(150)).await;
        r.input(&ben, "2").await
    };
    let off = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        admin_post(&r, "disable").await
    };
    let (_, queued, disabled) = tokio::join!(first, second, off);
    assert_eq!(disabled, StatusCode::OK);
    assert_eq!(
        queued.1["seq"], 0,
        "the waiting input did not run: {}",
        queued.1
    );
    assert_eq!(admin_post(&r, "enable").await, StatusCode::OK);
    assert_eq!(
        r.room(&ava).await,
        Value::Null,
        "no room came back after module_off"
    );
}

async fn admin_post(r: &RoomWorld, action: &str) -> StatusCode {
    let request = Request::builder()
        .method("POST")
        .uri(format!("/space/dock/modules/counter/{action}"))
        .header("authorization", format!("Bearer {}", r.w.token))
        .body(Body::empty())
        .unwrap();
    r.w.router.clone().oneshot(request).await.unwrap().status()
}
