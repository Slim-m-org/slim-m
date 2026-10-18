// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A webhook credential must never produce a `SessionContext`, so no
//! `Authed` extractor can ever accept one - the structural claim
//! `docs/decisions/0030-incoming-webhooks.md` makes, in the shape
//! `http/bots.rs`'s `require_human` makes for a bot not being able to
//! provision a bot, and the same "prove the gate can fail" discipline
//! `tests/rate_limit_coverage.rs` already applies to its own claim about
//! `Class::Read`.
//!
//! Two halves. A source-reading check that `Authed`'s implementation never
//! calls anything that could resolve a webhook credential - reading through
//! `support::code_only` so a comment naming `authenticate_webhook` cannot
//! satisfy it, the exact defect PR #553 found in eleven other source-reading
//! gates. And a behavioral check that a live webhook token, presented as an
//! ordinary bearer token, is refused on a real `Authed` route.
#![allow(dead_code)]

use std::path::Path;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

use support::app::app;

/// Reads `Authed`'s real implementation and asserts it never mentions
/// anything that could resolve a webhook credential to a session. If this
/// ever starts failing because `Authed` now calls `authenticate_webhook` or
/// constructs a `WebhookContext`, that is exactly the regression this file
/// exists to catch: a webhook holding a `SessionContext` would let it reach
/// every `Authed` route in the product, not just its one delivery route.
#[test]
fn authed_never_mentions_a_webhook_credential() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/http/extract.rs");
    let source = std::fs::read_to_string(&path).expect("read src/http/extract.rs");
    let scrubbed = support::code_only(&source);
    assert!(
        !scrubbed.contains("authenticate_webhook"),
        "Authed must never call Store::authenticate_webhook"
    );
    assert!(
        !scrubbed.contains("WebhookContext"),
        "Authed must never construct or accept a WebhookContext"
    );
}

/// The gate above must be able to fail, or it proves nothing - the same
/// argument `tests/rate_limit_coverage.rs` already makes for its own
/// source-reading checks.
#[test]
fn the_gate_would_catch_authed_resolving_a_webhook() {
    let sample = r#"
impl FromRequestParts<AppState> for Authed {
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        if let Some(ctx) = state.store.authenticate_webhook(id, &token).await? {
            return Ok(Authed(ctx.into_session()));
        }
        unreachable!()
    }
}
"#;
    let scrubbed = support::code_only(sample);
    assert!(scrubbed.contains("authenticate_webhook"));
}

/// A comment naming `authenticate_webhook` must not satisfy the gate.
#[test]
fn a_comment_mentioning_the_webhook_authenticator_does_not_satisfy_the_gate() {
    let sample = r#"
// Authed never calls authenticate_webhook or builds a WebhookContext.
impl Authed {}
"#;
    let scrubbed = support::code_only(sample);
    assert!(!scrubbed.contains("authenticate_webhook"));
    assert!(!scrubbed.contains("WebhookContext"));
}

/// The behavioral half: a live, unrevoked webhook token, presented exactly
/// the way a bearer token is, must be refused on a real `Authed` route
/// rather than resolving to anybody's session.
#[tokio::test]
async fn a_live_webhook_token_is_refused_as_a_bearer_token() {
    let (path, _guard) = support::TestDbGuard::new("slimm-webhook-never-a-session");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let store = Store::new(pool);

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

    let response = app(store)
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/me")
                .header("authorization", format!("Bearer {}", minted.token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "a webhook's own token must never resolve to a session on any Authed route"
    );
}
