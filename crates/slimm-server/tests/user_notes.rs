// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A caller's private note about another account: round-trips, is invisible
//! to everyone but its author, survives the subject being renamed, is purged
//! with the author's own account deletion, and masks an invisible subject
//! exactly like a nonexistent one.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

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
/// `tests/users.rs`'s own copy of this helper for why not `/auth/register`.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn put_note(app: &Router, token: &str, subject_id: &str, body: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/users/{subject_id}/note"),
            Some(token),
            Some(json!({ "body": body })),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    json_body(response).await
}

async fn get_note_status_and_body(
    app: &Router,
    token: &str,
    subject_id: &str,
) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/users/{subject_id}/note"),
            Some(token),
            None,
        ))
        .await
        .unwrap();
    let status = response.status();
    let body = if status == StatusCode::OK {
        json_body(response).await
    } else {
        Value::Null
    };
    (status, body)
}

#[tokio::test]
async fn a_note_round_trips() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let put_result = put_note(&app, &alice_token, &bob_id, "  prior warning, be careful  ").await;
    assert_eq!(
        put_result["body"], "prior warning, be careful",
        "trimmed on write"
    );
    assert!(put_result["updated_at"].is_i64());

    let (status, body) = get_note_status_and_body(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["body"], "prior warning, be careful");
    assert!(body["updated_at"].is_i64());
}

/// An empty (or whitespace-only) body clears the note rather than storing a
/// blank one - the same convention `Store::update_me`'s status text follows.
#[tokio::test]
async fn an_empty_body_clears_the_note() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    put_note(&app, &alice_token, &bob_id, "remember this").await;
    let cleared = put_note(&app, &alice_token, &bob_id, "   ").await;
    assert_eq!(cleared["body"], Value::Null);
    assert_eq!(cleared["updated_at"], Value::Null);

    let (status, body) = get_note_status_and_body(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["body"], Value::Null);
}

/// A note is never returned to anyone but the author who wrote it: not the
/// subject, and not an unrelated third member asking about the same subject.
/// Positive and negative sides both asserted, so a handler that always
/// answered null could not pass this alongside `a_note_round_trips`.
#[tokio::test]
async fn a_note_is_invisible_to_everyone_but_its_author() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;
    let (bob_token, bob_id) = register(&store, "bob").await;
    let (carol_token, _carol_id) = register(&store, "carol").await;

    put_note(
        &app,
        &alice_token,
        &bob_id,
        "alice's private note about bob",
    )
    .await;

    // Bob asking about himself never reaches alice's note about him: this route only ever answers for the caller's own note.
    let (bob_status, bob_body) = get_note_status_and_body(&app, &bob_token, &alice_id).await;
    assert_eq!(bob_status, StatusCode::OK);
    assert_eq!(
        bob_body["body"],
        Value::Null,
        "bob has left no note about alice; alice's note about bob must not leak here"
    );

    // Carol asking about the same subject bob gets her own (empty) answer, not alice's.
    let (carol_status, carol_body) = get_note_status_and_body(&app, &carol_token, &bob_id).await;
    assert_eq!(carol_status, StatusCode::OK);
    assert_eq!(carol_body["body"], Value::Null);

    // Alice's own read is unaffected by either of the above.
    let (alice_status, alice_body) = get_note_status_and_body(&app, &alice_token, &bob_id).await;
    assert_eq!(alice_status, StatusCode::OK);
    assert_eq!(alice_body["body"], "alice's private note about bob");
}

/// Keys on the subject's id, so a note is not lost or misfiled when the
/// subject changes their display name.
#[tokio::test]
async fn a_note_survives_the_subjects_rename() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let bob_user_id = slimm_server::ids::UserId(Uuid::parse_str(&bob_id).unwrap());

    put_note(&app, &alice_token, &bob_id, "prefers they/them").await;
    store
        .update_profile(
            bob_user_id,
            slimm_server::store::ProfileUpdate {
                display_name: Some("Bobby"),
                ..Default::default()
            },
        )
        .await
        .unwrap();

    let (status, body) = get_note_status_and_body(&app, &alice_token, &bob_id).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["body"], "prefers they/them");
}

/// The note is the author's own data: it is purged when the author deletes
/// their account, never when the subject does.
#[tokio::test]
async fn a_note_is_purged_when_the_author_deletes_their_account() {
    let (store, pool, _guard) = {
        let (path, guard) = support::TestDbGuard::new("slimm-user-notes-purge");
        let config = Config {
            port: 0,
            database_path: path,
            hash_concurrency: 2,
            ..Config::default()
        };
        let pool = db::connect(&config).await.expect("connect + migrate");
        (Store::new(pool.clone()), pool, guard)
    };

    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let author = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    let subject = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();

    store
        .set_user_note(
            author.id,
            subject.id,
            Some("a note that must not outlive alice"),
        )
        .await
        .unwrap();
    assert!(
        store
            .user_note(author.id, subject.id)
            .await
            .unwrap()
            .is_some(),
        "the note must exist before deletion, or this test proves nothing"
    );

    store.delete_account(author.id).await.unwrap();

    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_notes WHERE author_id = ?")
        .bind(author.id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        count, 0,
        "a leftover row keyed to a deleted author is a privacy bug"
    );
}

/// The subject's own deletion, by contrast, must not purge a note about them:
/// only the author's deletion does.
#[tokio::test]
async fn a_note_is_not_purged_when_the_subject_deletes_their_account() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let author = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(author.id).await.unwrap();
    let subject = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();

    store
        .set_user_note(author.id, subject.id, Some("kept even if bob leaves"))
        .await
        .unwrap();
    store.delete_account(subject.id).await.unwrap();

    // The row itself still exists (masked at the HTTP layer instead, tested separately); the store layer answers plainly.
    let note = store.user_note(author.id, subject.id).await.unwrap();
    assert_eq!(note.unwrap().body, "kept even if bob leaves");
}

/// A note about a subject with nothing live to answer for - never
/// registered, or since deleted - refuses identically either way, on both
/// verbs: the exact masking `tests/users.rs`'s
/// `a_deleted_account_looks_like_one_that_never_existed` pins for `getUser`.
#[tokio::test]
async fn a_note_about_an_invisible_user_is_masked_identically_to_one_about_a_nonexistent_user() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let bob_user_id = slimm_server::ids::UserId(Uuid::parse_str(&bob_id).unwrap());
    let never_existed = Uuid::now_v7().to_string();

    let (missing_get, _) = get_note_status_and_body(&app, &alice_token, &never_existed).await;
    let missing_put = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/users/{never_existed}/note"),
            Some(&alice_token),
            Some(json!({ "body": "x" })),
        ))
        .await
        .unwrap()
        .status();

    store.delete_account(bob_user_id).await.unwrap();

    let (deleted_get, _) = get_note_status_and_body(&app, &alice_token, &bob_id).await;
    let deleted_put = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/users/{bob_id}/note"),
            Some(&alice_token),
            Some(json!({ "body": "x" })),
        ))
        .await
        .unwrap()
        .status();

    assert_eq!(missing_get, StatusCode::NOT_FOUND);
    assert_eq!(deleted_get, missing_get);
    assert_eq!(missing_put, StatusCode::NOT_FOUND);
    assert_eq!(deleted_put, missing_put);
}

/// There is no note about yourself: both verbs refuse a self-target, and the
/// refusal is a plain 400, never the masked 404 - a caller always knows
/// their own id is real, so there is nothing to hide here.
#[tokio::test]
async fn a_note_about_yourself_is_refused() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, alice_id) = register(&store, "alice").await;

    let (get_status, _) = get_note_status_and_body(&app, &alice_token, &alice_id).await;
    assert_eq!(get_status, StatusCode::BAD_REQUEST);

    let put_status = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/users/{alice_id}/note"),
            Some(&alice_token),
            Some(json!({ "body": "x" })),
        ))
        .await
        .unwrap()
        .status();
    assert_eq!(put_status, StatusCode::BAD_REQUEST);
}

/// A note is a short annotation, not a document; the cap is inclusive at 500
/// characters after trimming.
#[tokio::test]
async fn the_length_cap_is_enforced() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let app = app(store.clone());
    let (alice_token, _alice_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;

    let at_cap = "a".repeat(500);
    let put_result = put_note(&app, &alice_token, &bob_id, &at_cap).await;
    assert_eq!(put_result["body"], at_cap);

    let over_cap = "a".repeat(501);
    let status = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/users/{bob_id}/note"),
            Some(&alice_token),
            Some(json!({ "body": over_cap })),
        ))
        .await
        .unwrap()
        .status();
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

/// A second write updates the note in place rather than accumulating rows,
/// and preserves `created_at` while `updated_at` moves - the guarantee the
/// `ON CONFLICT ... DO UPDATE` in `Store::set_user_note` exists to keep.
#[tokio::test]
async fn a_second_write_updates_in_place_and_keeps_created_at() {
    let (store, _guard) = support::new_store("slimm-user-notes-test").await;
    let alice = store
        .create_account("alice", "Alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();

    let first = store
        .set_user_note(alice.id, bob.id, Some("first"))
        .await
        .unwrap()
        .unwrap();
    let second = store
        .set_user_note(alice.id, bob.id, Some("second"))
        .await
        .unwrap()
        .unwrap();

    assert_eq!(second.body, "second");
    assert_eq!(
        second.created_at, first.created_at,
        "created_at must survive an update"
    );
}
