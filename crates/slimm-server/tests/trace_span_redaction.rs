// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `http.rs` labels its `TraceLayer` span by the matched route *template*,
//! never the raw request URI - see that file's own comment on why. This is
//! what stops a credential riding in a path, a webhook token or an invite
//! code, from being written into a debug-level log line.
//!
//! A scoped `tracing::subscriber::set_default` guard, not the global
//! registry `tests/permissions_batch_cost.rs` uses to count sqlx events:
//! that file needs a global subscriber because sqlx runs each connection on
//! a worker thread of its own, but span creation in `TraceLayer`'s
//! middleware happens inline on whatever task is driving the request, which
//! stays on this test's own thread under the default single-threaded
//! `#[tokio::test]` runtime.

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;
use tracing::field::{Field, Visit};
use tracing::span::Attributes;
use tracing::{Id, Subscriber};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

use support::app::app;

/// Every field value recorded on any span created while this layer is
/// installed, stringified. `Visit`'s typed methods (`record_str`,
/// `record_bool`, ...) all default to calling `record_debug`, so overriding
/// only that one method already sees every field regardless of its type.
#[derive(Clone, Default)]
struct CapturedSpanFields(Arc<Mutex<Vec<String>>>);

struct Recorder<'a>(&'a mut Vec<String>);

impl Visit for Recorder<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.0.push(format!("{}={value:?}", field.name()));
    }
}

impl<S: Subscriber> Layer<S> for CapturedSpanFields {
    fn on_new_span(&self, attrs: &Attributes<'_>, _id: &Id, _ctx: Context<'_, S>) {
        let mut values = Vec::new();
        attrs.record(&mut Recorder(&mut values));
        self.0.lock().unwrap().extend(values);
    }
}

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

#[tokio::test]
async fn a_webhook_delivery_span_never_carries_the_token() {
    let (store, _guard) = store("slimm-trace-webhook").await;
    let admin = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let minted = store
        .create_webhook(channel.id, "alerts", admin.id)
        .await
        .unwrap();

    let captured = CapturedSpanFields::default();
    let subscriber = Registry::default().with(captured.clone());
    let _default_guard = tracing::subscriber::set_default(subscriber);

    let path = format!("/webhooks/{}/{}", minted.webhook.id, minted.token);
    let response = app(store)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(&path)
                .header("content-type", "application/json")
                .body(Body::from(json!({ "content": "hi" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    let values = captured.0.lock().unwrap();
    let joined = values.join(" | ");
    assert!(
        !joined.contains(&minted.token),
        "a trace span carried the raw webhook token: {joined}"
    );
    assert!(
        joined.contains("/webhooks/{webhook_id}/{token}"),
        "expected the matched route template among the captured span fields, got: {joined}"
    );
}

#[tokio::test]
async fn an_invite_check_span_never_carries_the_code() {
    let (store, _guard) = store("slimm-trace-invite").await;
    let admin = store
        .create_account("root", "root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let invite = store
        .create_invite(admin.id, None, None, None)
        .await
        .expect("create an invite");

    let captured = CapturedSpanFields::default();
    let subscriber = Registry::default().with(captured.clone());
    let _default_guard = tracing::subscriber::set_default(subscriber);

    let response = app(store)
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/invites/{}/check", invite.code))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let values = captured.0.lock().unwrap();
    let joined = values.join(" | ");
    assert!(
        !joined.contains(&invite.code),
        "a trace span carried the raw invite code: {joined}"
    );
    assert!(
        joined.contains("/invites/{code}/check"),
        "expected the matched route template among the captured span fields, got: {joined}"
    );
}
