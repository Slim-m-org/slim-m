// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The HTTP-layer half of `crate::code_runner`'s broker: the permission gate,
//! the clean no-op an unconfigured runner is, the rate-limit charge, and that
//! a run through the reserved `code-runner` module id shows up in the exact
//! same discovery list and shared-run storage an installed module's would.
//! See docs/decisions/0026. Wire-level Piston behavior (timeouts, the
//! response byte ceiling, and what a request actually carries) is
//! `code_runner::piston`'s own unit tests; this file is about the broker
//! wired into the real router.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, post};
use serde_json::json;
use slimm_server::code_runner::CodeRunner;
use slimm_server::config::Config;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use tokio::net::TcpListener;
use tower::ServiceExt;

mod support;

use support::app::{json_body, request_json as request};

fn app(store: Store, code_runner: CodeRunner) -> Router {
    support::app::builder(store)
        .code_runner(code_runner)
        .router()
}

/// A fake Piston serving one fixed `/api/v2/runtimes` and always answering
/// `/api/v2/execute` with the same successful `output`.
async fn fake_piston() -> String {
    let router = Router::new()
        .route(
            "/api/v2/runtimes",
            get(|| async { axum::Json(json!([{ "language": "python", "version": "3.10.0" }])) }),
        )
        .route(
            "/api/v2/execute",
            post(|| async {
                axum::Json(json!({
                    "run": { "output": "42\n", "stdout": "42\n", "stderr": "", "code": 0, "signal": null }
                }))
            }),
        );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

fn code_runner_at(base_url: &str) -> CodeRunner {
    let config = Config {
        code_runner_url: Some(base_url.to_owned()),
        ..Config::default()
    };
    CodeRunner::new(&config).unwrap()
}

fn get_req(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

/// A fresh deployment with `@everyone` able to view and send, one channel,
/// and one registered member with no extra roles - the baseline every test
/// below grants `RUN_CODE` on top of, or does not.
async fn deployment(
    store: &Store,
) -> (
    slimm_server::ids::UserId,
    String,
    slimm_server::ids::ChannelId,
) {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let account = store
        .create_account("nia", "Nia", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token, channel.id)
}

async fn grant_run_code(store: &Store, user_id: slimm_server::ids::UserId) {
    let role = store
        .create_role("coders", Permissions::RUN_CODE, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
}

#[tokio::test]
async fn an_unconfigured_runner_is_a_clean_no_op_not_an_error() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (user_id, token, _channel) = deployment(&store).await;
    grant_run_code(&store, user_id).await;
    let router = app(store, CodeRunner::disabled());

    // Discovery lists nothing extra: no crash, just an empty list.
    let runners = json_body(
        router
            .clone()
            .oneshot(get_req("/modules/code-block-runners", &token))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(runners, json!([]));

    // Refused cleanly, not a 500 or a hang, even holding the permission.
    let response = router
        .oneshot(request(
            "POST",
            "/modules/code-runner/commands/python",
            &token,
            json!({ "input": "print(1)" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn the_broker_refuses_a_caller_without_run_code() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (_user_id, token, _channel) = deployment(&store).await;
    // Deliberately never granted.
    let base_url = fake_piston().await;
    let router = app(store, code_runner_at(&base_url));

    let runners = json_body(
        router
            .clone()
            .oneshot(get_req("/modules/code-block-runners", &token))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        runners,
        json!([]),
        "a configured runner must not be offered to a caller without RUN_CODE"
    );

    let response = router
        .oneshot(request(
            "POST",
            "/modules/code-runner/commands/python",
            &token,
            json!({ "input": "print(1)" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_permission_holder_can_run_through_the_configured_runner() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (user_id, token, _channel) = deployment(&store).await;
    grant_run_code(&store, user_id).await;
    let base_url = fake_piston().await;
    let router = app(store, code_runner_at(&base_url));

    let runners = json_body(
        router
            .clone()
            .oneshot(get_req("/modules/code-block-runners", &token))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        runners,
        json!([{ "module_id": "code-runner", "command": "python", "language": "python" }])
    );

    let response = router
        .oneshot(request(
            "POST",
            "/modules/code-runner/commands/python",
            &token,
            json!({ "input": "print(42)" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!({ "ok": true, "output": "42\n" })
    );
}

#[tokio::test]
async fn the_message_scoped_run_shares_and_stores_the_result() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (user_id, token, channel_id) = deployment(&store).await;
    grant_run_code(&store, user_id).await;
    let base_url = fake_piston().await;
    let router = app(store.clone(), code_runner_at(&base_url));

    let message_id = slimm_server::ids::MessageId::generate();
    store
        .send_message(NewMessage::plain(
            channel_id,
            user_id,
            message_id,
            "```python\nprint(42)\n```",
        ))
        .await
        .unwrap();

    let response = router
        .oneshot(request(
            "POST",
            &format!("/messages/{message_id}/blocks/0/run"),
            &token,
            json!({ "module_id": "code-runner", "command": "python", "input": "print(42)" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        json_body(response).await,
        json!({ "ok": true, "output": "42\n" })
    );

    let stored = store.code_runs_for_messages(&[message_id]).await.unwrap();
    assert_eq!(stored.len(), 1);
    let (_id, runs) = &stored[0];
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].module_id, "code-runner");
    assert_eq!(runs[0].command, "python");
    assert!(runs[0].ok);
    assert_eq!(runs[0].output, "42\n");
}

/// RUN_CODE is evaluated per channel for the message-scoped route, so a
/// channel overwrite can take it back even from someone who holds it at the
/// base (role) level - the same precedence every other channel-scoped
/// permission already has.
#[tokio::test]
async fn the_message_scoped_run_can_be_denied_by_a_channel_overwrite() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (user_id, token, channel_id) = deployment(&store).await;
    let role = store
        .create_role("coders", Permissions::RUN_CODE, false)
        .await
        .unwrap();
    store.assign_role(user_id, role).await.unwrap();
    store
        .set_role_overwrite(channel_id, role, Permissions::NONE, Permissions::RUN_CODE)
        .await
        .unwrap();
    let base_url = fake_piston().await;
    let router = app(store.clone(), code_runner_at(&base_url));

    let message_id = slimm_server::ids::MessageId::generate();
    store
        .send_message(NewMessage::plain(
            channel_id,
            user_id,
            message_id,
            "```python\nprint(42)\n```",
        ))
        .await
        .unwrap();

    let response = router
        .oneshot(request(
            "POST",
            &format!("/messages/{message_id}/blocks/0/run"),
            &token,
            json!({ "module_id": "code-runner", "command": "python", "input": "print(42)" }),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_code_runner_rate_limit_class_is_charged() {
    let (store, _guard) = support::new_store("slimm-code-runner-broker").await;
    let (user_id, token, _channel) = deployment(&store).await;
    grant_run_code(&store, user_id).await;
    let base_url = fake_piston().await;
    let router = app(store, code_runner_at(&base_url));

    // Class::CodeRunner bursts at 10, so the 11th immediate call is refused.
    let mut statuses = Vec::new();
    for _ in 0..11 {
        let response = router
            .clone()
            .oneshot(request(
                "POST",
                "/modules/code-runner/commands/python",
                &token,
                json!({ "input": "print(42)" }),
            ))
            .await
            .unwrap();
        statuses.push(response.status());
    }
    assert!(
        statuses[..10].iter().all(|s| *s == StatusCode::OK),
        "{statuses:?}"
    );
    assert_eq!(
        statuses[10],
        StatusCode::TOO_MANY_REQUESTS,
        "the 11th call must exceed Class::CodeRunner's burst: {statuses:?}"
    );
}
