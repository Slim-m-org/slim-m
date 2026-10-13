// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! GET /version: the unauthenticated probe onboarding uses to learn what a
//! server is before an account exists, including whether it can deliver push.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::gifs::GifSearch;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{MAX_SCREEN_SHARE_MAX_HEIGHT, Store};
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-version-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store, push: PushSender, gifs: GifSearch) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push,
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs,
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn get_version(app: Router) -> Value {
    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn version_reports_push_disabled_without_a_relay() {
    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;

    assert_eq!(body["name"], "slim-m");
    assert_eq!(body["protocol"], 1);
    assert!(body["version"].is_string());
    assert_eq!(body["push_enabled"], false);
}

#[tokio::test]
async fn version_reports_push_enabled_with_a_relay() {
    let config = Config {
        port: 0,
        database_path: String::new(),
        hash_concurrency: 2,
        push_relay_url: Some("https://relay.example".into()),
        push_relay_key: Some("smr_test".into()),
        ..Config::default()
    };
    let push = PushSender::new(&config).expect("relay config is valid");

    let (store, _guard) = new_store().await;
    let body = get_version(app(store, push, GifSearch::disabled())).await;
    assert_eq!(body["push_enabled"], true);
}

#[tokio::test]
async fn version_reports_gif_search_disabled_without_a_provider() {
    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;
    assert_eq!(body["gif_search_enabled"], false);
}

#[tokio::test]
async fn version_reports_gif_search_enabled_with_a_provider() {
    let config = Config {
        port: 0,
        database_path: String::new(),
        hash_concurrency: 2,
        gif_provider: Some("tenor".into()),
        gif_api_key: Some("test-key".into()),
        ..Config::default()
    };
    let gifs = GifSearch::new(&config).expect("provider config is valid");

    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), gifs)).await;
    assert_eq!(body["gif_search_enabled"], true);
}

/// Rides here unauthenticated, not behind `/space/screen-share`'s
/// MANAGE_SERVER gate, precisely so a member with no admin bit can still cap
/// their own screen share against it.
#[tokio::test]
async fn version_reports_the_screen_share_ceiling_with_no_auth_required() {
    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;
    assert_eq!(body["screen_share_max_height"], MAX_SCREEN_SHARE_MAX_HEIGHT);
}

#[tokio::test]
async fn version_reports_the_attachment_ceiling() {
    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;
    assert!(body["max_attachment_bytes"].as_u64().unwrap() > 0);
}

/// No floor is the ordinary case, and it has to be absent rather than null
/// or empty: a client reads "no field" as "this server does not gate on my
/// version", and an empty string would parse as a version nothing satisfies.
#[tokio::test]
async fn version_declares_no_client_floor_by_default() {
    unsafe { std::env::remove_var("SLIMM_MIN_CLIENT_VERSION") };

    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;

    assert!(
        body.get("min_client_version").is_none(),
        "an unset floor must not appear at all: {body}"
    );
}

/// The one lever an operator has when an old client genuinely cannot keep
/// working against a new server. Set per deployment, beside the build it
/// qualifies; see decision 0025.
#[tokio::test]
async fn version_publishes_the_client_floor_an_operator_set() {
    unsafe { std::env::set_var("SLIMM_MIN_CLIENT_VERSION", "0.76.0") };

    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;

    assert_eq!(body["min_client_version"], "0.76.0");

    unsafe { std::env::remove_var("SLIMM_MIN_CLIENT_VERSION") };
}

/// An operator who sets the variable to nothing at all means no floor, not a
/// floor of "": a blank value is how a compose file spells "leave it off".
#[tokio::test]
async fn version_reads_a_blank_floor_as_no_floor() {
    unsafe { std::env::set_var("SLIMM_MIN_CLIENT_VERSION", "   ") };

    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;

    assert!(
        body.get("min_client_version").is_none(),
        "blank is not a floor"
    );

    unsafe { std::env::remove_var("SLIMM_MIN_CLIENT_VERSION") };
}

/// The build id is baked in at compile time, so this asserts the wire agrees
/// with whatever this build was given: present and short when it was set,
/// absent (never null or a placeholder) when it was not.
#[tokio::test]
async fn version_reports_the_build_id_this_build_was_given() {
    let (store, _guard) = new_store().await;
    let body = get_version(app(store, PushSender::disabled(), GifSearch::disabled())).await;

    match slimm_server::http::build_id::from_raw(option_env!("SLIMM_BUILD_ID")) {
        Some(id) => assert_eq!(body["build_id"], id.as_str()),
        None => assert!(
            body.get("build_id").is_none(),
            "unset must be absent: {body}"
        ),
    }
}
