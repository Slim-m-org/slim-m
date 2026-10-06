// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /members?channel=` - the member pane's roster, narrowed to who can
//! view the channel it sits beside.
//!
//! Its own file rather than another case in `overwrites.rs`: that one is at
//! its line ceiling, and this is about the member list rather than about
//! setting an overwrite. The overwrite here is only the way to arrange a
//! channel somebody cannot see.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::permissions::Permissions;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-members-scope-test");
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

/// A member with a session, built straight through the store.
///
/// Deliberately not the `/auth/register` route: joining a claimed deployment
/// is an invite-gated policy decision, and it is pinned by its own tests in
/// `registration_gate.rs`. These tests only need somebody signed in, so going
/// through the store keeps them independent of that policy.
async fn register(store: &Store, username: &str) -> (String, String) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    // The first account here claims the deployment, as a real one does.
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}

async fn general_channel_id(store: &Store) -> String {
    store
        .list_channels()
        .await
        .unwrap()
        .into_iter()
        .next()
        .expect("bootstrap seeds a general channel")
        .id
        .to_string()
}

// --- Existence hiding ---

/// `GET /members?channel=` narrows the roster to who can view that channel,
/// and keeps doing so through the keyset the caller pages on.
///
/// The paging half is the part worth pinning. A caller stops when it gets a
/// page shorter than it asked for, so filtering a page after it was cut would
/// read as the end of the roster; with `limit=1` over a roster where the only
/// hidden member sits in the middle, a filter applied too late returns an
/// empty page and truncates everyone after them.
#[tokio::test]
async fn the_member_list_can_be_narrowed_to_a_channels_viewers() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (_carol_token, carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;

    let members = |uri: String| {
        let app = app.clone();
        let token = admin_token.clone();
        async move {
            let response = app
                .oneshot(request("GET", &uri, Some(&token), None))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            json_body(response)
                .await
                .as_array()
                .unwrap()
                .iter()
                .map(|m| m["id"].as_str().unwrap().to_string())
                .collect::<Vec<_>>()
        }
    };

    let everyone = members("/members".to_string()).await;
    assert_eq!(everyone.len(), 3, "three accounts, unfiltered");

    let viewers = members(format!("/members?channel={channel_id}")).await;
    assert_eq!(viewers, everyone, "nothing is denied yet, so nothing drops");

    let deny = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{bob_id}"),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(deny.status(), StatusCode::NO_CONTENT);

    let viewers = members(format!("/members?channel={channel_id}")).await;
    assert!(!viewers.contains(&bob_id), "bob cannot view it any more");
    assert!(viewers.contains(&admin_id) && viewers.contains(&carol_id));
    assert_eq!(
        members("/members".to_string()).await,
        everyone,
        "the unfiltered roster is untouched"
    );

    // Bob sits between alice and carol, so a late filter ends the paging here.
    let mut paged = Vec::new();
    let mut after: Option<String> = None;
    loop {
        let uri = match &after {
            Some(cursor) => format!("/members?channel={channel_id}&limit=1&after={cursor}"),
            None => format!("/members?channel={channel_id}&limit=1"),
        };
        let page = members(uri).await;
        if page.is_empty() {
            break;
        }
        after = page.last().cloned();
        paged.extend(page);
    }
    assert_eq!(paged, viewers, "paging one at a time sees the same people");
}

// --- Scope of the channel parameter ---

async fn get_members(app: &Router, token: &str, channel: &str) -> axum::response::Response {
    app.clone()
        .oneshot(request(
            "GET",
            &format!("/members?channel={channel}"),
            Some(token),
            None,
        ))
        .await
        .unwrap()
}

/// Naming a channel the caller cannot view must not reveal who can, nor that
/// the channel exists: a restricted channel, a dm between two other people and
/// an unknown id all answer the same 404.
#[tokio::test]
async fn a_channel_the_caller_cannot_view_is_not_a_viewer_oracle() {
    let (store, _guard) = new_store().await;
    let app = app(store.clone());
    let (admin_token, admin_id) = register(&store, "alice").await;
    let (_bob_token, bob_id) = register(&store, "bob").await;
    let (carol_token, carol_id) = register(&store, "carol").await;
    let channel_id = general_channel_id(&store).await;

    let deny = app
        .clone()
        .oneshot(request(
            "PUT",
            &format!("/channels/{channel_id}/overwrites/member/{carol_id}"),
            Some(&admin_token),
            Some(json!({ "allow": 0, "deny": Permissions::VIEW_CHANNEL.bits() })),
        ))
        .await
        .unwrap();
    assert_eq!(deny.status(), StatusCode::NO_CONTENT);
    let user_id = |raw: &str| slimm_server::ids::UserId(uuid::Uuid::parse_str(raw).unwrap());
    let dm = store
        .open_dm(user_id(&admin_id), user_id(&bob_id))
        .await
        .unwrap();

    let restricted = get_members(&app, &carol_token, &channel_id).await;
    let in_dm = get_members(&app, &carol_token, &dm.id.to_string()).await;
    let unknown = get_members(&app, &carol_token, &uuid::Uuid::now_v7().to_string()).await;

    assert_eq!(restricted.status(), StatusCode::NOT_FOUND);
    assert_eq!(in_dm.status(), StatusCode::NOT_FOUND);
    assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
    let unknown = json_body(unknown).await;
    assert_eq!(json_body(restricted).await, unknown);
    assert_eq!(json_body(in_dm).await, unknown);
}
