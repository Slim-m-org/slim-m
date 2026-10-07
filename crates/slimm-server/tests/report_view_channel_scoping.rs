// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A moderator denied `VIEW_CHANNEL` on one channel must not read its reports.
//!
//! The queue already filtered per channel, and already had a test for it - but
//! that test denies `MANAGE_MESSAGES` directly, which is the one shape the
//! filter did handle. Denying only `VIEW_CHANNEL` left the moderation bit
//! intact, and the filter asked about nothing else: `channels_where` began as
//! a `VIEW_CHANNEL` question and was generalised to take the permission as a
//! parameter for this queue's sake, which dropped the view requirement instead
//! of adding to it.
//!
//! So a moderator explicitly shut out of one channel still read every report
//! filed there, `snapshot` text included - the verbatim reported message - plus
//! the reporter's id and confirmation the channel exists. Denying
//! `VIEW_CHANNEL` alone is the ordinary way to keep a channel private from
//! moderators who still moderate everywhere else, which is what makes this
//! worth its own file rather than a case bolted onto `report_paging.rs`.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::Value;
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;
use support::reports::StoreReportExt;

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

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn reports(app: &Router, token: &str) -> Vec<Value> {
    let response = app.clone().oneshot(get("/reports", token)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn admin(store: &Store) -> (UserId, ChannelId) {
    let account = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    (account.id, channel)
}

/// A moderator holding deployment-wide `MANAGE_MESSAGES`, with a session.
async fn moderator(store: &Store) -> (UserId, String) {
    let account = store
        .create_account("mod", "Mod", "not-a-real-hash")
        .await
        .unwrap();
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(account.id, role).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    (account.id, token)
}

/// Files a report about a fresh message in `channel`, returning its text.
async fn report_in(store: &Store, channel: ChannelId, author: UserId, body: &str) -> String {
    let subject = store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
        .message
        .id;
    let reporter = store
        .create_user(&format!("r{body}"), "Reporter")
        .await
        .unwrap();
    store
        .file_report(
            reporter.id,
            slimm_server::store::ReportSubject::Message(subject),
            "not ok",
        )
        .await
        .unwrap();
    body.to_owned()
}

/// The deliverable. Denying only `VIEW_CHANNEL` must hide that channel's
/// reports, exactly as denying `MANAGE_MESSAGES` already did.
#[tokio::test]
async fn a_moderator_denied_only_view_channel_cannot_read_that_channels_reports() {
    let (store, _guard) = new_store("slimm-report-view-scoping").await;
    let (author, open_channel) = admin(&store).await;
    let secret = store.create_channel("secret", "text").await.unwrap().id;
    let (mod_id, mod_token) = moderator(&store).await;

    // The moderation bit is deliberately left intact; only sight is removed.
    store
        .set_member_overwrite(secret, mod_id, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();

    let hidden_text = report_in(&store, secret, author, "secret-text").await;
    let open_text = report_in(&store, open_channel, author, "open-text").await;

    let app = app(store.clone());
    let queue = reports(&app, &mod_token).await;

    let serialized = serde_json::to_string(&queue).unwrap();
    assert!(
        !serialized.contains(&hidden_text),
        "the reported message's own text leaked from a channel this moderator \
         cannot see: {serialized}"
    );
    assert!(
        !serialized.contains(&secret.to_string()),
        "the hidden channel's id leaked, confirming it exists: {serialized}"
    );
    assert!(
        serialized.contains(&open_text),
        "the report from a channel they can moderate must still be listed, or \
         this test would pass on an empty queue: {serialized}"
    );
}

/// The other half of the same gap: the resolve verb re-checks visibility
/// through its own path, so fixing only the listing would leave a moderator
/// able to dismiss a report they can no longer read.
#[tokio::test]
async fn a_moderator_denied_only_view_channel_cannot_resolve_that_channels_reports() {
    let (store, _guard) = new_store("slimm-report-view-resolve").await;
    let (author, _open) = admin(&store).await;
    let secret = store.create_channel("secret", "text").await.unwrap().id;
    let (mod_id, mod_token) = moderator(&store).await;
    store
        .set_member_overwrite(secret, mod_id, Permissions::NONE, Permissions::VIEW_CHANNEL)
        .await
        .unwrap();
    report_in(&store, secret, author, "secret-text").await;

    let open = store.list_open_reports(None, &[], 50).await.unwrap();
    let report_id = open.first().expect("one open report").id;

    let response = app(store.clone())
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/reports/{report_id}"))
                .header("authorization", format!("Bearer {mod_token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"resolution":"dismissed"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    // Not-found rather than forbidden: saying "forbidden" would confirm it exists.
    assert_eq!(
        response.status(),
        StatusCode::NOT_FOUND,
        "dismissing a report from a channel they cannot see must be refused"
    );
}

/// The control that stops the two tests above passing for the wrong reason: a
/// moderator who can see the channel still gets the report, snapshot and all.
#[tokio::test]
async fn a_moderator_who_can_see_the_channel_still_reads_its_reports() {
    let (store, _guard) = new_store("slimm-report-view-control").await;
    let (author, _open) = admin(&store).await;
    let visible = store.create_channel("visible", "text").await.unwrap().id;
    let (_mod_id, mod_token) = moderator(&store).await;
    let text = report_in(&store, visible, author, "visible-text").await;

    let queue = reports(&app(store.clone()), &mod_token).await;
    let serialized = serde_json::to_string(&queue).unwrap();
    assert!(
        serialized.contains(&text),
        "with no overwrite denying sight, the report must be readable: \
         {serialized}"
    );
}
