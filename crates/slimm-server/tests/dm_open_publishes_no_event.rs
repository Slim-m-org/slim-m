// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Whether opening a DM publishes any hub event at all - the answer a
//! recipient's `SyncController` workaround (`sync_controller.dart`) depends
//! on. `POST /channels` publishes `Event::ChannelCreated` in the same
//! handler that creates the row (`http/channels.rs`); `open` (`http/dms.rs`)
//! never has. This is the standing proof of that, rather than a claim in a
//! comment nobody re-checks. See `dms.rs` for every other DM invariant; this
//! lives on its own because that file already sits at its own 591-line
//! allowlist ceiling.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::hub::Hub;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::register_token_id as register;

fn app_with_hub(store: Store, hub: Hub) -> Router {
    support::app::builder(store).hub(hub).router()
}

/// `POST /channels` publishes `Event::ChannelCreated` in the same handler
/// that creates the row; opening a DM never has, which is why the client
/// materialises a DM's channel from a live `MessageCreated` frame rather
/// than trusting a `ChannelCreated` frame that will never arrive for one. A
/// future change that starts publishing here should be a deliberate
/// decision made alongside revisiting that client workaround, not a silent
/// drift - this test is what makes the drift loud.
#[tokio::test]
async fn opening_a_dm_publishes_no_hub_event() {
    let (store, _guard) = support::new_store("slimm-dm-open-event-test").await;
    let hub = Hub::new();
    let app = app_with_hub(store.clone(), hub.clone());
    let mut rx = hub.subscribe();

    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/dms/{bob_id}"))
                .header("authorization", format!("Bearer {alice_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    assert!(
        rx.try_recv().is_err(),
        "opening a DM must not publish any hub event"
    );
}
