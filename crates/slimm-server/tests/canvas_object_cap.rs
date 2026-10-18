// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-channel canvas object cap as a space setting: its default, the
//! config round trip over HTTP, its MANAGE_SERVER gate, and the settable
//! range. The cap's actual enforcement at placement is covered in
//! `canvas_write/write.rs` (`a_lowered_cap_refuses_the_next_object`).

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::{
    MAX_CANVAS_OBJECT_CAP, MAX_OBJECTS_PER_CHANNEL, MIN_CANVAS_OBJECT_CAP, Store,
};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_id as register, request_authed as request};

async fn harness(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

/// The default a deployment keeps on upgrade is the compile-time object
/// ceiling, so behaviour is unchanged until an admin sets its own. Pins the
/// migration DEFAULT to the constant, which is otherwise free to drift.
#[tokio::test]
async fn the_cap_defaults_to_the_object_ceiling() {
    let (s, _guard) = harness("slimm-canvas-cap-default").await;
    assert_eq!(
        s.canvas_object_cap().await.unwrap(),
        MAX_OBJECTS_PER_CHANNEL
    );
}

#[tokio::test]
async fn the_cap_round_trips_over_http() {
    let (s, _guard) = harness("slimm-canvas-cap-roundtrip").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);

    let response = router
        .clone()
        .oneshot(request(
            "PATCH",
            "/space/canvas-cap",
            &session.access_token,
            Some(json!({"object_cap": 5000})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(json_body(response).await["object_cap"], json!(5000));

    let response = router
        .oneshot(request(
            "GET",
            "/space/canvas-cap",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(json_body(response).await["object_cap"], json!(5000));
}

#[tokio::test]
async fn updating_the_cap_requires_manage_server() {
    let (s, _guard) = harness("slimm-canvas-cap-forbidden").await;
    let _admin = register(&s, "root").await;
    let member = s.create_user("nia", "Nia").await.unwrap();
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);

    let response = router
        .oneshot(request(
            "PATCH",
            "/space/canvas-cap",
            &session.access_token,
            Some(json!({"object_cap": 5000})),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn an_out_of_range_cap_is_refused() {
    let (s, _guard) = harness("slimm-canvas-cap-range").await;
    let admin = register(&s, "root").await;
    let session = s.open_session(admin, "laptop").await.unwrap();
    let router = app(s);

    for bad in [MIN_CANVAS_OBJECT_CAP - 1, MAX_CANVAS_OBJECT_CAP + 1] {
        let response = router
            .clone()
            .oneshot(request(
                "PATCH",
                "/space/canvas-cap",
                &session.access_token,
                Some(json!({ "object_cap": bad })),
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "a cap of {bad} is out of range and must be refused"
        );
    }
}
