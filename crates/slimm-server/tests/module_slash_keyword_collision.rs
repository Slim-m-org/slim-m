// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Two enabled modules may not share a slash keyword: the composer would run whichever was listed first.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModuleRuntimeLimits, Store,
};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

async fn store(name: &str) -> (Store, support::TestDbGuard) {
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

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: VoiceService::disabled(),
        media: Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

async fn install(s: &Store, id: &str, keyword: &str) {
    let extension_points = [ModuleExtensionPointSpec {
        kind: "slash-command",
        name: keyword,
        description: None,
        permission: Some("use"),
        command: Some("run"),
        language: None,
    }];
    s.install_module_with_artifact(
        InstallModuleRequest {
            id,
            name: id,
            version: "1.0.0",
            artifact_sha256: "00",
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[],
            extension_points: &extension_points,
        },
        b"stub-artifact",
    )
    .await
    .unwrap();
}

async fn post(router: &Router, token: &str, uri: &str) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn enabling_a_module_whose_keyword_is_taken_is_refused_until_the_owner_is_disabled() {
    let (s, _guard) = store("slimm-slash-collision").await;
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let token = session.access_token.as_str();
    install(&s, "dice", "roll").await;
    install(&s, "other-dice", "ROLL").await;
    install(&s, "poll", "poll").await;
    let router = app(s);

    let (status, _) = post(&router, token, "/space/dock/modules/dice/enable").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = post(&router, token, "/space/dock/modules/poll/enable").await;
    assert_eq!(status, StatusCode::OK);

    let (status, body) = post(&router, token, "/space/dock/modules/other-dice/enable").await;
    assert_eq!(status, StatusCode::CONFLICT);
    let message = body["error"].as_str().unwrap();
    assert!(
        message.contains("/roll") && message.contains("dice"),
        "{message}"
    );

    let (status, _) = post(&router, token, "/space/dock/modules/dice/disable").await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = post(&router, token, "/space/dock/modules/other-dice/enable").await;
    assert_eq!(status, StatusCode::OK);
}
