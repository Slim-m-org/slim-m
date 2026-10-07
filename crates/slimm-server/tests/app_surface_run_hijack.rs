// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message-scoped run route (`super::code_runs` in the server) took
//! `module_id` straight from the caller's own body and never consulted
//! `app_surfaces` - the table that records which module actually launched a
//! message. Naming a different, unrelated module the caller happened to hold
//! a permission for let them overwrite another module's shared, broadcast
//! surface. Covers the hijack itself, that the surface's own module keeps
//! working, and that a plain code block with no app surface is unaffected.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{
    InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
    NewMessage, Store, User,
};
use tower::ServiceExt;
use uuid::Uuid;

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
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
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

/// Installs a module with one `run` command, gated on its own `play`
/// permission, and (when `as_app`) an `app` extension point launching it.
async fn install(s: &Store, module_id: &'static str, output: &str, as_app: bool) {
    let wasm = canned_ok_wasm(output);
    let sha256 = sha256_hex(&wasm);
    let mut extension_points = vec![ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: Some("runs it"),
        permission: Some("play"),
        command: None,
        language: None,
    }];
    if as_app {
        extension_points.push(ModuleExtensionPointSpec {
            kind: "app",
            name: module_id,
            description: Some("launch it"),
            permission: Some("play"),
            command: Some("run"),
            language: None,
        });
    }
    s.install_module_with_artifact(
        InstallModuleRequest {
            id: module_id,
            name: module_id,
            version: "0.1.0",
            artifact_sha256: &sha256,
            approved_capabilities: &[],
            runtime_limits: &ModuleRuntimeLimits::default(),
            permissions: &[ModulePermissionSpec {
                key: "play",
                name: "Play",
                description: "play it",
            }],
            extension_points: &extension_points,
        },
        &wasm,
    )
    .await
    .unwrap();
    s.set_module_enabled(module_id, true).await.unwrap();
}

/// Grants `module_id:play` to a fresh role and assigns it to `user`.
async fn grant_play(s: &Store, user: &User, module_id: &str) {
    let role = s
        .create_role(&format!("{module_id}-players"), Permissions::NONE, false)
        .await
        .unwrap();
    s.assign_role(user.id, role).await.unwrap();
    s.grant_module_permission(role, module_id, "play")
        .await
        .unwrap();
}

fn post(uri: &str, token: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A fresh deployment: `@everyone` can view and send, one channel, `life`
/// installed as a launchable app, `dice` installed as a plain command, an
/// owner holding `life:play`, and an attacker holding only `dice:play`.
async fn scene(s: &Store) -> (User, User, ChannelId, String, String) {
    s.create_role(
        "everyone",
        Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
        true,
    )
    .await
    .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let owner = s.create_user("orin", "Orin").await.unwrap();
    let attacker = s.create_user("adell", "Adell").await.unwrap();
    install(s, "life", "alive", true).await;
    install(s, "dice", "rolled a 4", false).await;
    grant_play(s, &owner, "life").await;
    grant_play(s, &attacker, "dice").await;
    let owner_token = s
        .open_session(owner.id, "phone")
        .await
        .unwrap()
        .access_token;
    let attacker_token = s
        .open_session(attacker.id, "phone")
        .await
        .unwrap()
        .access_token;
    (owner, attacker, channel.id, owner_token, attacker_token)
}

/// Launches `life` as an app surface in `channel_id` and returns the message id.
async fn launch_life(router: &Router, channel_id: ChannelId, owner_token: &str) -> MessageId {
    let launch = json_body(
        router
            .clone()
            .oneshot(post(
                &format!("/channels/{channel_id}/messages/apps"),
                owner_token,
                json!({
                    "id": Uuid::now_v7().to_string(),
                    "content": "life is running",
                    "module_id": "life",
                    "command": "run",
                }),
            ))
            .await
            .unwrap(),
    )
    .await;
    MessageId(Uuid::parse_str(launch["id"].as_str().unwrap()).unwrap())
}

/// The hijack the discovery agent reproduced: an attacker who holds no
/// permission for `life` cannot name it directly (an existing, separate
/// gate), but naming `dice` - a module they *do* hold a permission for -
/// against `life`'s own message and block must also be refused, and the
/// surface's stored run must survive untouched.
#[tokio::test]
async fn naming_an_unrelated_permitted_module_cannot_overwrite_an_app_surface() {
    let (s, _guard) = new_store("slimm-app-surface-hijack").await;
    let (_owner, _attacker, channel_id, owner_token, attacker_token) = scene(&s).await;
    let router = app(s.clone());

    let message_id = launch_life(&router, channel_id, &owner_token).await;
    let seeded = router
        .clone()
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &owner_token,
            json!({ "module_id": "life", "command": "run", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(seeded.status(), StatusCode::OK);

    let direct = router
        .clone()
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &attacker_token,
            json!({ "module_id": "life", "command": "run", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(
        direct.status(),
        StatusCode::FORBIDDEN,
        "naming life directly with no life permission is the separate, already-fixed gate"
    );

    let hijack = router
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &attacker_token,
            json!({ "module_id": "dice", "command": "run", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(
        hijack.status(),
        StatusCode::FORBIDDEN,
        "a permission for an unrelated module must not reach a surface it does not own"
    );

    let stored = s.code_runs_for_messages(&[message_id]).await.unwrap();
    let (_id, runs) = &stored[0];
    assert_eq!(runs.len(), 1);
    assert_eq!(
        runs[0].module_id, "life",
        "the shared row must still be life's, not dice's"
    );
    assert_eq!(runs[0].output, "alive");
}

/// The gate this fix adds must not block the surface's own module: the
/// permission holder for the module that actually launched the surface can
/// still run it, repeatedly, on its own block.
#[tokio::test]
async fn the_surfaces_own_module_can_still_run_on_its_own_block() {
    let (s, _guard) = new_store("slimm-app-surface-own-module").await;
    let (_owner, _attacker, channel_id, owner_token, _attacker_token) = scene(&s).await;
    let router = app(s.clone());

    let message_id = launch_life(&router, channel_id, &owner_token).await;
    for _ in 0..2 {
        let response = router
            .clone()
            .oneshot(post(
                &format!("/messages/{message_id}/blocks/0/run"),
                &owner_token,
                json!({ "module_id": "life", "command": "run", "input": "" }),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    let stored = s.code_runs_for_messages(&[message_id]).await.unwrap();
    let (_id, runs) = &stored[0];
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].module_id, "life");
    assert!(runs[0].ok);
}

/// A message with no `app_surfaces` row at all - an ordinary fenced code
/// block - is unaffected by this gate: any permission holder for the named
/// module may still run it, exactly as before.
#[tokio::test]
async fn a_plain_code_block_with_no_app_surface_is_unaffected() {
    let (s, _guard) = new_store("slimm-app-surface-plain-block").await;
    let (owner, _attacker, channel_id, _owner_token, attacker_token) = scene(&s).await;
    let router = app(s.clone());

    let message_id = MessageId::generate();
    s.send_message(NewMessage::plain(
        channel_id,
        owner.id,
        message_id,
        "```\nroll it\n```",
    ))
    .await
    .unwrap();

    let response = router
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &attacker_token,
            json!({ "module_id": "dice", "command": "run", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let stored = s.code_runs_for_messages(&[message_id]).await.unwrap();
    let (_id, runs) = &stored[0];
    assert_eq!(runs[0].module_id, "dice");
    assert_eq!(runs[0].output, "rolled a 4");
}

/// The module alone is not the surface's key: its own module naming another command is refused.
#[tokio::test]
async fn the_surfaces_own_module_with_another_command_is_refused() {
    let (s, _guard) = new_store("slimm-app-surface-other-command").await;
    let (_owner, _attacker, channel_id, owner_token, _attacker_token) = scene(&s).await;
    let router = app(s.clone());

    let message_id = launch_life(&router, channel_id, &owner_token).await;
    let response = router
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/0/run"),
            &owner_token,
            json!({ "module_id": "life", "command": "other", "input": "" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let stored = s.code_runs_for_messages(&[message_id]).await.unwrap();
    assert!(stored.iter().all(|(_, runs)| runs.is_empty()));
}
