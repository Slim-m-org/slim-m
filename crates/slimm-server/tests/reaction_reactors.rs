// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /messages/{id}/reactions/{emoji}`: who left one reaction, as the
//! viewer is allowed to see them. The list must always hold exactly as many
//! people as the tally the same viewer is shown.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::{NewMessage, Store};
use tower::ServiceExt;

mod support;

const THUMB: &str = "\u{1F44D}";
const THUMB_PATH: &str = "%F0%9F%91%8D";
const HEART_PATH: &str = "%E2%9D%A4%EF%B8%8F";

async fn new_store(prefix: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app_with(store: Store, limiter: RateLimiter) -> Router {
    support::app::builder(store).limiter(limiter).router()
}

fn app(store: Store) -> Router {
    app_with(store, RateLimiter::new())
}

fn get(uri: &str, token: &str) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap()
}

async fn fetch(app: &Router, uri: &str, token: &str) -> (StatusCode, Value) {
    let response = app.clone().oneshot(get(uri, token)).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, body)
}

struct Member {
    id: UserId,
    token: String,
}

async fn member(store: &Store, username: &str) -> Member {
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
    Member {
        id: account.id,
        token,
    }
}

async fn open_room(store: &Store) -> ChannelId {
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ADD_REACTIONS),
            true,
        )
        .await
        .unwrap();
    store.create_channel("general", "text").await.unwrap().id
}

async fn post(store: &Store, channel: ChannelId, author: UserId) -> MessageId {
    let id = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel, author, id, "react to me"))
        .await
        .unwrap();
    id
}

/// Reactions land a few milliseconds apart so "ordered by when" is observable.
async fn react(store: &Store, message: MessageId, user: UserId, emoji: &str) {
    store.add_reaction(message, user, emoji).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(4)).await;
}

fn ids(body: &Value) -> Vec<String> {
    body["users"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["user_id"].as_str().unwrap().to_owned())
        .collect()
}

/// The count the messages route shows this viewer for `emoji`, 0 if absent.
async fn tally(app: &Router, channel: ChannelId, token: &str, emoji: &str) -> usize {
    let (status, page) = fetch(app, &format!("/channels/{channel}/messages"), token).await;
    assert_eq!(status, StatusCode::OK);
    page[0]["reactions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["emoji"] == emoji)
        .map_or(0, |r| r["count"].as_u64().unwrap() as usize)
}

#[tokio::test]
async fn the_list_names_every_reactor_in_the_order_they_reacted() {
    let (store, _guard) = new_store("slimm-reactors-plain").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let bob = store.create_user("bob", "Bob").await.unwrap();
    let cy = store.create_user("cy", "Cy").await.unwrap();
    let message = post(&store, channel, alice.id).await;
    react(&store, message, cy.id, THUMB).await;
    react(&store, message, alice.id, THUMB).await;
    react(&store, message, bob.id, THUMB).await;
    react(&store, message, bob.id, "\u{2764}\u{FE0F}").await;

    let app = app(store);
    let uri = format!("/messages/{message}/reactions/{THUMB_PATH}");
    let (status, body) = fetch(&app, &uri, &alice.token).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        ids(&body),
        vec![cy.id.to_string(), alice.id.to_string(), bob.id.to_string()]
    );
    assert!(body["next_cursor"].is_null());
    assert_eq!(
        ids(&body).len(),
        tally(&app, channel, &alice.token, THUMB).await
    );
    let (_, hearts) = fetch(
        &app,
        &format!("/messages/{message}/reactions/{HEART_PATH}"),
        &alice.token,
    )
    .await;
    assert_eq!(ids(&hearts), vec![bob.id.to_string()]);
}

/// Each arrangement is checked against the tally the same viewer is given, in
/// both directions: the tally hides only reactors the viewer blocked, so a
/// reactor who blocked the viewer stays in both, and so must the list.
#[tokio::test]
async fn the_list_is_exactly_as_long_as_the_tally_under_every_block_arrangement() {
    let (store, _guard) = new_store("slimm-reactors-blocks").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let pest = store.create_user("pest", "Pest").await.unwrap();
    let troll = store.create_user("troll", "Troll").await.unwrap();
    let carol = store.create_user("carol", "Carol").await.unwrap();
    let message = post(&store, channel, alice.id).await;
    for user in [pest.id, troll.id, carol.id, alice.id] {
        react(&store, message, user, THUMB).await;
    }
    let app = app(store.clone());
    let uri = format!("/messages/{message}/reactions/{THUMB_PATH}");

    let check = |expected: Vec<UserId>| {
        let (app, uri, token) = (app.clone(), uri.clone(), alice.token.clone());
        async move {
            let (_, body) = fetch(&app, &uri, &token).await;
            let got = ids(&body);
            assert_eq!(got.len(), tally(&app, channel, &token, THUMB).await);
            assert_eq!(
                got,
                expected
                    .iter()
                    .map(std::string::ToString::to_string)
                    .collect::<Vec<_>>()
            );
        }
    };

    check(vec![pest.id, troll.id, carol.id, alice.id]).await;

    store.block_user(alice.id, pest.id).await.unwrap();
    check(vec![troll.id, carol.id, alice.id]).await;

    store.block_user(alice.id, troll.id).await.unwrap();
    check(vec![carol.id, alice.id]).await;

    // The other direction: carol blocking alice changes nothing for alice.
    store.block_user(carol.id, alice.id).await.unwrap();
    check(vec![carol.id, alice.id]).await;

    // Everyone else blocked: only her own reaction is left, never an error.
    store.block_user(alice.id, carol.id).await.unwrap();
    check(vec![alice.id]).await;

    // An emoji whose only reactors are blocked is an empty list and no tally.
    let only_blocked = MessageId::generate();
    store
        .send_message(NewMessage::plain(channel, pest.id, only_blocked, "x"))
        .await
        .unwrap();
    store
        .add_reaction(only_blocked, pest.id, THUMB)
        .await
        .unwrap();
    let (status, body) = fetch(
        &app,
        &format!("/messages/{only_blocked}/reactions/{THUMB_PATH}"),
        &alice.token,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(ids(&body).is_empty());
}

#[tokio::test]
async fn a_blocked_reactor_is_still_listed_for_everyone_else() {
    let (store, _guard) = new_store("slimm-reactors-blocker-alone").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let dana = member(&store, "dana").await;
    let pest = store.create_user("pest", "Pest").await.unwrap();
    let message = post(&store, channel, alice.id).await;
    react(&store, message, pest.id, THUMB).await;
    store.block_user(alice.id, pest.id).await.unwrap();

    let app = app(store);
    let uri = format!("/messages/{message}/reactions/{THUMB_PATH}");
    let (_, for_alice) = fetch(&app, &uri, &alice.token).await;
    let (_, for_dana) = fetch(&app, &uri, &dana.token).await;
    assert!(ids(&for_alice).is_empty());
    assert_eq!(ids(&for_dana), vec![pest.id.to_string()]);
}

#[tokio::test]
async fn a_viewer_who_cannot_read_the_channel_gets_the_missing_message_answer() {
    let (store, _guard) = new_store("slimm-reactors-hidden").await;
    store
        .create_role("everyone", Permissions::ADD_REACTIONS, true)
        .await
        .unwrap();
    let channel = store.create_channel("private", "text").await.unwrap().id;
    let stranger = member(&store, "stranger").await;
    let author = store.create_user("author", "Author").await.unwrap();
    let message = post(&store, channel, author.id).await;
    store.add_reaction(message, author.id, THUMB).await.unwrap();

    let app = app(store);
    let (hidden_status, hidden_body) = fetch(
        &app,
        &format!("/messages/{message}/reactions/{THUMB_PATH}"),
        &stranger.token,
    )
    .await;
    let missing = MessageId::generate();
    let (missing_status, missing_body) = fetch(
        &app,
        &format!("/messages/{missing}/reactions/{THUMB_PATH}"),
        &stranger.token,
    )
    .await;
    assert_eq!(hidden_status, StatusCode::NOT_FOUND);
    assert_eq!(
        (hidden_status, &hidden_body),
        (missing_status, &missing_body)
    );
    assert!(!hidden_body.to_string().contains(&author.id.to_string()));
}

#[tokio::test]
async fn a_deleted_message_has_no_reactor_list() {
    let (store, _guard) = new_store("slimm-reactors-deleted").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let message = post(&store, channel, alice.id).await;
    store.add_reaction(message, alice.id, THUMB).await.unwrap();
    let app = app(store.clone());
    let delete = Request::builder()
        .method("DELETE")
        .uri(format!("/channels/{channel}/messages/{message}"))
        .header("authorization", format!("Bearer {}", alice.token))
        .body(Body::empty())
        .unwrap();
    assert!(
        app.clone()
            .oneshot(delete)
            .await
            .unwrap()
            .status()
            .is_success()
    );

    let (status, _) = fetch(
        &app,
        &format!("/messages/{message}/reactions/{THUMB_PATH}"),
        &alice.token,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_emoji_nobody_used_is_an_empty_list() {
    let (store, _guard) = new_store("slimm-reactors-unused").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let message = post(&store, channel, alice.id).await;
    let app = app(store);
    let (status, body) = fetch(
        &app,
        &format!("/messages/{message}/reactions/{THUMB_PATH}"),
        &alice.token,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({ "users": [], "next_cursor": null }));
}

#[tokio::test]
async fn pages_follow_the_cursor_in_reaction_order_without_gaps_or_repeats() {
    let (store, _guard) = new_store("slimm-reactors-pages").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let message = post(&store, channel, alice.id).await;
    let mut order = Vec::new();
    for i in 0..5 {
        let user = store
            .create_user(&format!("u{i}"), &format!("U{i}"))
            .await
            .unwrap();
        react(&store, message, user.id, THUMB).await;
        order.push(user.id.to_string());
    }

    let app = app(store);
    let base = format!("/messages/{message}/reactions/{THUMB_PATH}");
    let mut seen = Vec::new();
    let mut uri = format!("{base}?limit=2");
    let mut pages = 0;
    loop {
        let (status, body) = fetch(&app, &uri, &alice.token).await;
        assert_eq!(status, StatusCode::OK);
        pages += 1;
        seen.extend(ids(&body));
        match body["next_cursor"].as_str() {
            Some(cursor) => uri = format!("{base}?limit=2&after={cursor}"),
            None => break,
        }
    }
    assert_eq!(pages, 3);
    assert_eq!(seen, order);

    let (status, _) = fetch(&app, &format!("{base}?after=garbage"), &alice.token).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_bot_reactor_is_listed_like_anyone_else() {
    let (store, _guard) = new_store("slimm-reactors-bot").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let bot = store
        .create_bot("helper", "Helper", Permissions::ADD_REACTIONS, alice.id)
        .await
        .unwrap()
        .bot;
    let message = post(&store, channel, alice.id).await;
    react(&store, message, bot.user_id, THUMB).await;

    let app = app(store);
    let (_, body) = fetch(
        &app,
        &format!("/messages/{message}/reactions/{THUMB_PATH}"),
        &alice.token,
    )
    .await;
    assert_eq!(ids(&body), vec![bot.user_id.to_string()]);
}

#[tokio::test]
async fn the_route_charges_the_authed_read_class() {
    let (store, _guard) = new_store("slimm-reactors-rate").await;
    let channel = open_room(&store).await;
    let alice = member(&store, "alice").await;
    let message = post(&store, channel, alice.id).await;
    let app = app_with(store, RateLimiter::with_trusted_hops(0));
    let uri = format!("/messages/{message}/reactions/{THUMB_PATH}");
    let mut limited = false;
    for _ in 0..80 {
        if fetch(&app, &uri, &alice.token).await.0 == StatusCode::TOO_MANY_REQUESTS {
            limited = true;
            break;
        }
    }
    assert!(limited, "AuthedRead's burst is 40; 80 reads must hit it");
}
