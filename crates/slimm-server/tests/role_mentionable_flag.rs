// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Role.mentionable`, over `POST /roles` and `PATCH /roles/{roleId}`: set at
//! creation, toggled by itself afterward, and treated as a real field by the
//! "nothing to update" refusal - split out of `tests/roles.rs` (whose own
//! concerns are the MANAGE_ROLES gate, escalation, and the last-administrator
//! invariant) once adding this pushed that file past the 500-line ceiling.
//! Resolution of `@[Role Name]` against this flag is `tests/role_mentions.rs`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
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

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A member with a session, built straight through the store; see
/// `tests/roles.rs`'s identical helper for why this skips `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

/// `mentionable` can be set at creation, toggled by itself afterward without
/// resending `name`/`permissions`, and a genuinely empty patch is refused
/// the same way it already is when neither of those two is present.
#[tokio::test]
async fn mentionable_can_be_set_at_creation_and_toggled_on_its_own() {
    let (store, _guard) = support::new_store("slimm-role-mentionable-flag").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(json!({
                    "name": "Core Team",
                    "permissions": 0,
                    "mentionable": true,
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let role_id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["mentionable"], true);

    let toggled_off = json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/roles/{role_id}"),
                Some(&admin_token),
                Some(json!({ "mentionable": false })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(toggled_off["mentionable"], false);
    // Untouched fields survive a mentionable-only update.
    assert_eq!(toggled_off["name"], "Core Team");

    let empty_patch = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{role_id}"),
            Some(&admin_token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(empty_patch.status(), StatusCode::BAD_REQUEST);
}

/// A retry of an idempotent create (the same client-supplied id twice) must
/// not re-apply `mentionable` a second time - see the note on
/// `create`/`CreatedRole::fresh` in `http/roles.rs`. Proven here rather than
/// in `role_create_idempotency.rs` since it is specifically about this
/// field's own opt-in-on-fresh-create-only behaviour.
#[tokio::test]
async fn mentionable_at_creation_is_not_reapplied_on_a_retried_create() {
    let (store, _guard) = support::new_store("slimm-role-mentionable-flag").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let id = uuid::Uuid::now_v7().to_string();

    let first = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "id": id, "name": "Core Team", "permissions": 0, "mentionable": true })),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(first).await["mentionable"], true);

    // A retry with mentionable omitted must not read as unsetting it.
    let retried = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "id": id, "name": "Core Team", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(retried).await["mentionable"],
        true,
        "a retry must not touch a field the first create already set"
    );
}
