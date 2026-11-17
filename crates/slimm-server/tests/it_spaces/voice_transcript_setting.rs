// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space setting for voice message transcripts: off by default, managers
//! only, and refused as a 409 on a server with no speech listener.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http;

use crate::support;
use support::app::call;
use support::overwrite_harness::{new_store, register};

#[tokio::test]
async fn it_is_off_and_unavailable_without_a_listener_and_cannot_be_turned_on() {
    let (store, _guard) = new_store("slimm-voice-transcript-setting").await;
    let (admin, _) = register(&store, "root").await;
    let (member, _) = register(&store, "nia").await;
    let router = http::router(support::app::state(store));

    let (_, settings) = call(&router, "GET", "/space/settings", Some(&admin), None).await;
    assert_eq!(settings["transcribe_voice_messages"], false);
    assert_eq!(settings["transcribe_voice_messages_available"], false);

    let on = json!({"transcribe_voice_messages": true});
    let (status, _) = call(
        &router,
        "PATCH",
        "/space/settings",
        Some(&admin),
        Some(on.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    let (status, _) = call(&router, "PATCH", "/space/settings", Some(&member), Some(on)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let off = json!({"transcribe_voice_messages": false});
    let (status, body) = call(&router, "PATCH", "/space/settings", Some(&admin), Some(off)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["transcribe_voice_messages"], false);
}
