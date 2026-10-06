// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Paging the moderation queue: the cursor, the clamp, and the ordering of the
//! per-channel filter against the limit.
//!
//! That ordering is the one worth a file of its own. The queue is filtered per
//! channel because a report carries the reported content verbatim, and doing
//! that *after* a `LIMIT` makes a short page ambiguous - a caller cannot tell it
//! from the end of the queue - so a moderator denied MANAGE_MESSAGES in one busy
//! channel stops paging with readable reports still ahead of them.
//!
//! Its own file rather than added to `reports.rs` (373 lines), which covers the
//! permission bar itself and is past the review budget already.

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
use uuid::Uuid;

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

async fn json_array(app: &Router, uri: &str, token: &str) -> Vec<Value> {
    let response = app.clone().oneshot(get(uri, token)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK, "GET {uri}");
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// An administrator with a session, and the deployment claimed by them.
async fn admin(store: &Store, username: &str) -> (UserId, String, ChannelId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let token = store
        .open_session(account.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.list_channels().await.unwrap()[0].id;
    (account.id, token, channel)
}

async fn message(store: &Store, channel: ChannelId, author: UserId, body: &str) -> MessageId {
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            body,
        ))
        .await
        .unwrap()
        .message
        .id
}

/// The queue answered with every open report in the deployment, and the handler
/// then re-checks visibility channel by channel at several indexed queries
/// each. It answers one page now, and pages forward on `created_at`.
#[tokio::test]
async fn the_report_queue_answers_a_page_and_pages_forward() {
    let (store, _guard) = new_store("slimm-bounds-reports").await;
    let (moderator, token, channel) = admin(&store, "root").await;
    let reporter = store.create_user("bob", "Bob").await.unwrap();

    // One report per subject: the store allows only one open report per pair.
    for index in 0..7 {
        let subject = message(&store, channel, moderator, &format!("m{index}")).await;
        store
            .file_report(
                reporter.id,
                slimm_server::store::ReportSubject::Message(subject),
                "not ok",
            )
            .await
            .unwrap();
    }

    let first = json_array(&app(store.clone()), "/reports?limit=3", &token).await;
    assert_eq!(first.len(), 3, "a limit must bound the page");

    let last = first.last().unwrap();
    let after = last["created_at"].as_i64().unwrap();
    let after_id = last["id"].as_str().unwrap();
    let next = json_array(
        &app(store.clone()),
        &format!("/reports?limit=3&after={after}&after_id={after_id}"),
        &token,
    )
    .await;
    assert!(
        !next.is_empty(),
        "the cursor must reach the rest of the queue"
    );
    let first_ids: Vec<&str> = first.iter().map(|r| r["id"].as_str().unwrap()).collect();
    for report in &next {
        assert!(
            !first_ids.contains(&report["id"].as_str().unwrap()),
            "a page must not repeat the previous one"
        );
    }
}

/// A caller asking for everything gets a page, not everything. Without the
/// clamp the limit is the caller's to choose, which is the same unbounded read
/// with an extra step.
#[tokio::test]
async fn an_absurd_report_limit_is_clamped() {
    let (store, _guard) = new_store("slimm-bounds-report-limit").await;
    let (moderator, token, channel) = admin(&store, "root").await;
    let reporter = store.create_user("bob", "Bob").await.unwrap();
    for index in 0..4 {
        let subject = message(&store, channel, moderator, &format!("m{index}")).await;
        store
            .file_report(
                reporter.id,
                slimm_server::store::ReportSubject::Message(subject),
                "not ok",
            )
            .await
            .unwrap();
    }

    let all = json_array(&app(store.clone()), "/reports?limit=999999", &token).await;
    assert_eq!(all.len(), 4, "the clamp is a ceiling, not a floor");

    let zero = json_array(&app(store.clone()), "/reports?limit=0", &token).await;
    assert_eq!(
        zero.len(),
        1,
        "a limit under one clamps up, never to nothing"
    );
}

/// A cursor past the end yields nothing rather than wrapping.
#[tokio::test]
async fn a_cursor_past_the_end_yields_nothing() {
    let (store, _guard) = new_store("slimm-bounds-cursor-end").await;
    let (_moderator, token, _channel) = admin(&store, "root").await;
    let uri = format!("/reports?after={}&after_id={}", i64::MAX, Uuid::max());
    assert!(
        json_array(&app(store.clone()), &uri, &token)
            .await
            .is_empty()
    );
}

/// Half a cursor is refused rather than read as the timestamp-only form it
/// replaced, which skipped a whole tied group at a page boundary.
#[tokio::test]
async fn half_a_cursor_is_refused() {
    let (store, _guard) = new_store("slimm-bounds-half-cursor").await;
    let (_moderator, token, _channel) = admin(&store, "root").await;
    let app = app(store.clone());
    let response = app
        .clone()
        .oneshot(get("/reports?after=1", &token))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let uri = format!("/reports?after_id={}", Uuid::now_v7());
    let response = app.oneshot(get(&uri, &token)).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

/// Reports sharing one millisecond are paged through, not skipped. The
/// timestamp-only cursor this replaced excluded the whole tied value, so every
/// remaining member of a group straddling a page boundary was lost for good.
#[tokio::test]
async fn a_page_boundary_inside_one_millisecond_skips_nothing() {
    let (store, _guard) = new_store("slimm-bounds-tie").await;
    let (moderator, token, channel) = admin(&store, "root").await;

    for index in 0..5 {
        let reporter = store
            .create_user(&format!("r{index}"), "Reporter")
            .await
            .unwrap();
        let subject = message(&store, channel, moderator, &format!("m{index}")).await;
        store
            .file_report(
                reporter.id,
                slimm_server::store::ReportSubject::Message(subject),
                "not ok",
            )
            .await
            .unwrap();
    }

    let mut seen: Vec<String> = Vec::new();
    let mut cursor: Option<(i64, String)> = None;
    for _ in 0..10 {
        let uri = match &cursor {
            None => "/reports?limit=2".to_owned(),
            Some((after, id)) => format!("/reports?limit=2&after={after}&after_id={id}"),
        };
        let page = json_array(&app(store.clone()), &uri, &token).await;
        if page.is_empty() {
            break;
        }
        for report in &page {
            let id = report["id"].as_str().unwrap().to_owned();
            assert!(!seen.contains(&id), "a page repeated a report");
            seen.push(id);
        }
        let last = page.last().unwrap();
        cursor = Some((
            last["created_at"].as_i64().unwrap(),
            last["id"].as_str().unwrap().to_owned(),
        ));
    }

    assert_eq!(
        seen.len(),
        5,
        "every report must be reachable by paging, whatever the timestamps"
    );
}

/// The property a post-filter could not have: a page whose raw window is
/// entirely invisible still comes back holding the readable report.
///
/// Filtering after the `LIMIT` made a short page mean either "some of this
/// window was restricted" or "the queue ended", and nothing in the response
/// told them apart - so a moderator denied MANAGE_MESSAGES in one busy channel
/// stopped paging with reports they were entitled to read still ahead of them,
/// and a fully-hidden first window read as an empty queue. `reports.rs` already
/// covers that such a report is hidden at all; this covers that hiding it does
/// not cost the caller the rest of the queue.
#[tokio::test]
async fn a_page_whose_window_is_all_hidden_still_yields_the_readable_report() {
    let (store, _guard) = new_store("slimm-bounds-hidden-window").await;
    let (author, admin_token, open_channel) = admin(&store, "root").await;
    let reporter = store.create_user("bob", "Bob").await.unwrap();
    let closed = store.create_channel("secret", "text").await.unwrap().id;

    let moderator = store
        .create_account("mod", "Mod", "not-a-real-hash")
        .await
        .unwrap();
    let role = store
        .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
        .await
        .unwrap();
    store.assign_role(moderator.id, role).await.unwrap();
    store
        .set_member_overwrite(
            closed,
            moderator.id,
            Permissions::NONE,
            Permissions::MANAGE_MESSAGES,
        )
        .await
        .unwrap();
    let mod_token = store
        .open_session(moderator.id, "cli")
        .await
        .unwrap()
        .access_token;

    // Hidden ones first, so a raw window of two holds nothing readable.
    for (channel, label) in [(closed, "s0"), (closed, "s1"), (open_channel, "o0")] {
        let subject = message(&store, channel, author, label).await;
        let one_reporter = store
            .create_user(&format!("r{label}"), "Reporter")
            .await
            .unwrap();
        let _ = reporter;
        store
            .file_report(
                one_reporter.id,
                slimm_server::store::ReportSubject::Message(subject),
                "not ok",
            )
            .await
            .unwrap();
    }

    let page = json_array(&app(store.clone()), "/reports?limit=2", &mod_token).await;
    assert_eq!(
        page.len(),
        1,
        "the hidden pair is excluded before the limit, so the readable one \
         arrives in the first page rather than being paged past"
    );
    assert_eq!(
        page[0]["channel_id"].as_str().unwrap(),
        open_channel.to_string()
    );

    let all = json_array(&app(store.clone()), "/reports", &admin_token).await;
    assert_eq!(all.len(), 3, "an administrator still sees all three");
}
