// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member under a timeout cannot write the shared run output of a code block
//! or app surface: the run is stored and shown to everyone in the channel, so
//! it is a write like a message, not a private computation.

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

mod support;
use support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

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
async fn install(s: &Store, module_id: &'static str, output: &str) {
    let wasm = canned_ok_wasm(output);
    let sha256 = sha256_hex(&wasm);
    let extension_points = vec![ModuleExtensionPointSpec {
        kind: "command",
        name: "run",
        description: Some("runs it"),
        permission: Some("play"),
        command: None,
        language: None,
    }];
    s.install_module(InstallModuleRequest {
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
    })
    .await
    .unwrap();
    s.store_module_artifact(module_id, &sha256, &wasm)
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

async fn scene(s: &Store) -> (User, User, ChannelId, String) {
    s.create_role(
        "everyone",
        Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
        true,
    )
    .await
    .unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    let author = s.create_user("orin", "Orin").await.unwrap();
    let runner = s.create_user("adell", "Adell").await.unwrap();
    install(s, "dice", "rolled a 4").await;
    grant_play(s, &author, "dice").await;
    grant_play(s, &runner, "dice").await;
    let runner_token = s
        .open_session(runner.id, "phone")
        .await
        .unwrap()
        .access_token;
    (author, runner, channel.id, runner_token)
}

async fn run(router: &Router, message_id: MessageId, token: &str, input: &str) -> StatusCode {
    run_block(router, message_id, 0, token, input).await
}

async fn run_block(
    router: &Router,
    message_id: MessageId,
    block_index: i64,
    token: &str,
    input: &str,
) -> StatusCode {
    router
        .clone()
        .oneshot(post(
            &format!("/messages/{message_id}/blocks/{block_index}/run"),
            token,
            json!({ "module_id": "dice", "command": "run", "input": input }),
        ))
        .await
        .unwrap()
        .status()
}

async fn post_block(s: &Store, channel_id: ChannelId, author: &User, body: &str) -> MessageId {
    let id = MessageId::generate();
    s.send_message(NewMessage::plain(channel_id, author.id, id, body))
        .await
        .unwrap();
    id
}

#[tokio::test]
async fn a_timed_out_member_cannot_write_shared_run_output() {
    let (s, _guard) = new_store("slimm-code-run-timeout").await;
    let (author, runner, channel_id, runner_token) = scene(&s).await;
    let router = app(s.clone());
    let id = post_block(&s, channel_id, &author, "```js\nroll()\n```").await;

    // control: the same member runs fine before the timeout
    assert_eq!(
        run(&router, id, &runner_token, "roll()").await,
        StatusCode::OK
    );

    let until = now_ms() + 3_600_000;
    s.set_member_timeout(runner.id, until, Some("cool off"), author.id)
        .await
        .unwrap();

    // control: the timeout is in force (cannot send a message)
    let send = router
        .clone()
        .oneshot(post(
            &format!("/channels/{channel_id}/messages"),
            &runner_token,
            json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "hi" }),
        ))
        .await
        .unwrap()
        .status();
    assert_eq!(send, StatusCode::FORBIDDEN, "timeout must block sending");

    let status = run(&router, id, &runner_token, "roll()").await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "timed-out member overwrote shared run output"
    );
}
