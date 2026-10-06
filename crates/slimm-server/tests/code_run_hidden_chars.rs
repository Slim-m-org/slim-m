// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A code block whose bytes hide text-direction or zero-width characters
//! (the trojan-source shape, CVE-2021-42574) renders as something other than
//! what a module would receive. The shared run route refuses to run one, for
//! every caller including the author, and decides it from the stored message
//! and the request input rather than from anything the client claims.

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
async fn install(s: &Store, module_id: &'static str, output: &str, _as_app: bool) {
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
    if false {
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

async fn scene(s: &Store) -> (User, User, ChannelId, String, String) {
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
    install(s, "dice", "rolled a 4", false).await;
    grant_play(s, &author, "dice").await;
    grant_play(s, &runner, "dice").await;
    let author_token = s
        .open_session(author.id, "phone")
        .await
        .unwrap()
        .access_token;
    let runner_token = s
        .open_session(runner.id, "phone")
        .await
        .unwrap()
        .access_token;
    (author, runner, channel.id, author_token, runner_token)
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

const HIDDEN: [char; 9] = [
    '\u{202A}', '\u{202D}', '\u{202E}', '\u{2066}', '\u{2069}', '\u{200E}', '\u{200F}', '\u{200B}',
    '\u{FEFF}',
];

#[tokio::test]
async fn a_block_hiding_direction_or_zero_width_characters_is_refused_for_everyone() {
    let (s, _guard) = new_store("slimm-hidden-chars-refused").await;
    let (author, _runner, channel_id, author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    for hidden in HIDDEN {
        let code = format!("if (isAdmin {hidden}) {{ ok() }}");
        let id = post_block(&s, channel_id, &author, &format!("```js\n{code}\n```")).await;
        for token in [&runner_token, &author_token] {
            assert_eq!(
                run(&router, id, token, &code).await,
                StatusCode::FORBIDDEN,
                "U+{:04X} must refuse a run",
                hidden as u32
            );
        }
    }
}

#[tokio::test]
async fn hidden_characters_in_prose_beside_the_block_do_not_block_a_clean_run() {
    let (s, _guard) = new_store("slimm-hidden-chars-input").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let body = "family \u{1F468}\u{200D}\u{1F469}\n```js\nroll()\n```";
    let id = post_block(&s, channel_id, &author, body).await;
    assert_eq!(
        run(&router, id, &runner_token, "roll()").await,
        StatusCode::OK
    );
}

#[tokio::test]
async fn ordinary_code_with_tabs_newlines_and_unicode_text_still_runs() {
    let (s, _guard) = new_store("slimm-hidden-chars-ordinary").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let code = "if (x) {\r\n\tlog(\"caf\u{e9} \u{4e16}\u{754c}\");\n}";
    let id = post_block(&s, channel_id, &author, &format!("```js\n{code}\n```")).await;
    assert_eq!(run(&router, id, &runner_token, code).await, StatusCode::OK);
}

#[tokio::test]
async fn a_refused_run_stores_nothing() {
    let (s, _guard) = new_store("slimm-hidden-chars-stores-nothing").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let code = "roll()\u{202E}";
    let id = post_block(&s, channel_id, &author, &format!("```js\n{code}\n```")).await;
    assert_eq!(
        run(&router, id, &runner_token, code).await,
        StatusCode::FORBIDDEN
    );
    let stored = s.code_runs_for_messages(&[id]).await.unwrap();
    assert!(stored.iter().all(|(_, runs)| runs.is_empty()));
}

#[tokio::test]
async fn the_stored_block_is_judged_not_the_input_a_client_sends() {
    let (s, _guard) = new_store("slimm-run-extracts-stored-block").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let hidden = post_block(&s, channel_id, &author, "```js\nroll()\u{202E}\n```").await;
    assert_eq!(
        run(&router, hidden, &runner_token, "roll()").await,
        StatusCode::FORBIDDEN,
        "a clean input cannot launder a block that hides characters"
    );

    let clean = post_block(&s, channel_id, &author, "```js\nroll()\n```").await;
    assert_eq!(
        run(&router, clean, &runner_token, "attack()\u{202E}").await,
        StatusCode::OK,
        "the stored block runs, whatever input the client claims"
    );
}

#[tokio::test]
async fn a_block_index_with_no_block_is_a_conflict_and_stores_nothing() {
    let (s, _guard) = new_store("slimm-run-no-such-block").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let one = post_block(&s, channel_id, &author, "```js\nroll()\n```").await;
    assert_eq!(
        run_block(&router, one, 1, &runner_token, "roll()").await,
        StatusCode::CONFLICT
    );
    let prose = post_block(&s, channel_id, &author, "no code here").await;
    assert_eq!(
        run(&router, prose, &runner_token, "roll()").await,
        StatusCode::CONFLICT
    );
    let stored = s.code_runs_for_messages(&[one, prose]).await.unwrap();
    assert!(stored.iter().all(|(_, runs)| runs.is_empty()));
}

#[tokio::test]
async fn the_second_block_runs_by_its_own_index_after_an_edit_moves_it() {
    let (s, _guard) = new_store("slimm-run-stale-index").await;
    let (author, _runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());

    let id = post_block(&s, channel_id, &author, "```js\na()\n```\n```js\nb()\n```").await;
    assert_eq!(
        run_block(&router, id, 1, &runner_token, "").await,
        StatusCode::OK
    );
    s.edit_message(id, "```js\na()\n```", author.id)
        .await
        .unwrap();
    assert_eq!(
        run_block(&router, id, 1, &runner_token, "").await,
        StatusCode::CONFLICT,
        "an index from before the edit no longer names a block"
    );
}

#[tokio::test]
async fn a_member_who_cannot_see_the_channel_gets_404_and_nothing_is_stored() {
    let (s, _guard) = new_store("slimm-run-hidden-channel").await;
    let (author, runner, channel_id, _author_token, runner_token) = scene(&s).await;
    let router = app(s.clone());
    let id = post_block(&s, channel_id, &author, "```js\nroll()\n```").await;
    s.set_member_overwrite(
        channel_id,
        runner.id,
        Permissions::NONE,
        Permissions::VIEW_CHANNEL,
    )
    .await
    .unwrap();

    assert_eq!(
        run(&router, id, &runner_token, "roll()").await,
        StatusCode::NOT_FOUND
    );
    let stored = s.code_runs_for_messages(&[id]).await.unwrap();
    assert!(stored.iter().all(|(_, runs)| runs.is_empty()));
}
