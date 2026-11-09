// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every documented operation that needs a session refuses a caller without one.
//!
//! Authentication is a per-handler extractor, not a router layer, so a handler
//! that loses its `Authed` extractor silently becomes public: it still
//! compiles, still matches `schema/openapi.yaml`, and `rate_limit_coverage`
//! only inspects handlers that already take `Authed`. This drives every
//! operation the schema does not mark `security: []` with no token and with a
//! token that never existed, and wants a 401 from each.
//!
//! The request carries well-formed path ids and an empty JSON body on
//! purpose: a handler that parses either before it authenticates would answer
//! 404, 400 or 422 to a stranger instead of 401.
//!
//! The crate-level `dead_code` allow covers the shared `support` module: an
//! integration test is its own crate, so every helper this binary does not
//! call reads as unused.
#![allow(dead_code)]

use std::collections::BTreeSet;
use std::path::Path;

use axum::http::StatusCode;
use serde_json::json;

mod support;

use support::app::{builder, call};
use support::openapi::{Method, SchemaRoute, extract_schema_routes};

/// Operations the schema marks `security: []`, each with why it takes no bearer token.
///
/// Adding to the schema's public set without adding here fails the first test.
const PUBLIC: &[(&str, &str)] = &[
    ("getHealth", "liveness probe"),
    ("getVersion", "probed from the login screen"),
    ("register", "makes the account a token comes from"),
    ("login", "trades a password for a token"),
    ("refresh", "trades a refresh token for a token"),
    ("resetPassword", "an admin-issued code is the credential"),
    (
        "verifyTotpChallenge",
        "the login challenge precedes a session",
    ),
    (
        "discordLinkCallback",
        "a browser redirect with signed state",
    ),
    ("checkInvite", "a prospective member checks a code"),
    ("inviteLandingPage", "the shareable page for an invite"),
    ("getInviteBanner", "the landing page's banner"),
    ("getInviteIcon", "the landing page's icon"),
    ("receiveLiveKitWebhook", "LiveKit signs the delivery"),
    ("deliverWebhook", "the secret is in the path"),
    (
        "connectWebSocket",
        "the upgrade carries a single-use ticket",
    ),
];

/// Fewer than this many documented operations means the extractor lost most of the schema.
const MIN_OPERATIONS: usize = 150;

const SOME_ID: &str = "019e0000-0000-7000-8000-000000000001";

fn schema_routes() -> Vec<SchemaRoute> {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .expect("crates/slimm-server is two directories below the repo root");
    extract_schema_routes(repo_root)
}

fn operation(route: &SchemaRoute) -> String {
    route
        .operation_id
        .clone()
        .unwrap_or_else(|| format!("{} {}", route.method.as_str(), route.path))
}

/// The path with every `{param}` replaced by a well-formed id.
fn concrete_path(template: &str) -> String {
    let mut out = String::new();
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        out.push_str(SOME_ID);
        rest = &rest[rest.find('}').expect("closed path parameter") + 1..];
    }
    out.push_str(rest);
    out
}

fn has_body(method: Method) -> bool {
    matches!(method, Method::Post | Method::Put | Method::Patch)
}

#[test]
fn the_public_operations_are_exactly_the_listed_ones() {
    let routes = schema_routes();
    assert!(
        routes.len() >= MIN_OPERATIONS,
        "the schema extractor found {} operations, expected at least {MIN_OPERATIONS}",
        routes.len()
    );
    let documented: BTreeSet<String> = routes
        .iter()
        .filter(|route| route.public)
        .map(operation)
        .collect();
    let listed: BTreeSet<String> = PUBLIC.iter().map(|(id, _)| (*id).to_owned()).collect();
    assert_eq!(
        documented, listed,
        "schema `security: []` operations and PUBLIC must agree; an operation that stops \
         needing a session has to be a deliberate edit here"
    );
}

#[tokio::test]
async fn every_session_operation_refuses_a_stranger() {
    let (store, _db) = support::new_store("slimm-unauth-refusal").await;
    let router = builder(store).router();
    let public: BTreeSet<&str> = PUBLIC.iter().map(|(id, _)| *id).collect();
    let tokens = [None, Some("not-a-real-token")];

    let mut checked = 0usize;
    let mut leaks = Vec::new();
    for route in schema_routes() {
        let id = operation(&route);
        if public.contains(id.as_str()) {
            continue;
        }
        let uri = concrete_path(&route.path);
        let body = has_body(route.method).then(|| json!({}));
        for token in tokens {
            let (status, _) = call(&router, route.method.as_str(), &uri, token, body.clone()).await;
            checked += 1;
            if status != StatusCode::UNAUTHORIZED {
                let who = token.map_or("no token", |_| "a bogus token");
                leaks.push(format!(
                    "{id} ({} {}) answered {status} to {who}",
                    route.method.as_str(),
                    route.path
                ));
            }
        }
    }

    assert!(checked > 0, "no operation was exercised");
    assert!(
        leaks.is_empty(),
        "these operations did not answer 401 to a caller without a session; \
         take an Authed extractor before any Path or Json one:\n  {}",
        leaks.join("\n  ")
    );
}
