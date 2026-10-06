// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every route that loads a message by id and masks a hidden one as missing
//! answers with the same 404 text, so the routes agree with each other as well
//! as each hiding the message from itself.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

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

async fn answer(app: &Router, method: &str, uri: &str, token: &str, body: Value) -> Value {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND, "{method} {uri}");
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn a_hidden_message_gets_one_404_text_on_every_route() {
    let (path, _guard) = support::TestDbGuard::new("slimm-hidden-message-404");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    store
        .create_role("everyone", Permissions::NONE, true)
        .await
        .unwrap();
    let hidden = store.create_channel("private", "text").await.unwrap();
    let account = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let author = store.create_user("author", "Author").await.unwrap();
    let message = MessageId::generate();
    store
        .send_message(NewMessage::plain(hidden.id, author.id, message, "secret"))
        .await
        .unwrap();
    let app = app(store);

    let routes = [
        ("PUT", format!("/messages/{message}/reactions/x"), json!({})),
        ("GET", format!("/messages/{message}/reactions/x"), json!({})),
        (
            "PUT",
            format!("/messages/{message}/polls/vote"),
            json!({ "option": 0 }),
        ),
        (
            "POST",
            format!("/messages/{message}/blocks/0/run"),
            json!({ "module_id": "m", "command": "c", "input": "" }),
        ),
        ("PUT", format!("/messages/{message}/save"), json!({})),
        (
            "POST",
            "/reports".to_owned(),
            json!({ "subject_kind": "message", "subject_id": message.to_string(), "reason": "spam" }),
        ),
    ];
    for (method, uri, body) in routes {
        let reply = answer(&app, method, &uri, &token, body).await;
        assert_eq!(reply["error"], "no such message", "{method} {uri}: {reply}");
    }
}
