// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Ranked-choice polls: rankings stored whole and replaced whole, the
//! instant-runoff result on reads and in the fan-out event, and ballots
//! refused when they do not fit the poll.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tokio::net::TcpListener;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::request_authed as request;

type WsClient =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct World {
    store: Store,
    state: AppState,
    app: Router,
    channel: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world() -> World {
    let (path, guard) = support::TestDbGuard::new("slimm-polls-ranked");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.expect("connect + migrate"));
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let state = support::app::state(store.clone());
    World {
        store,
        app: http::router(state.clone()),
        state,
        channel,
        _guard: guard,
    }
}

async fn send(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
    let response = app.clone().oneshot(req).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

/// A signed-in member with a ws ticket, made through the store.
async fn member(store: &Store, name: &str) -> (String, String) {
    let user = store.create_user(name, name).await.unwrap();
    let tokens = store.open_session(user.id, "device").await.unwrap();
    let ctx = store
        .authenticate(&tokens.access_token)
        .await
        .unwrap()
        .unwrap();
    let (ticket, _expires_at) = store.mint_ws_ticket(&ctx).await.unwrap();
    (tokens.access_token, ticket)
}

async fn create(w: &World, token: &str, options: &[&str], ranked: bool) -> String {
    let body = json!({
        "id": Uuid::now_v7().to_string(),
        "question": "where to?",
        "options": options,
        "ranked": ranked,
    });
    let uri = format!("/channels/{}/messages/polls", w.channel);
    let (status, poll) = send(&w.app, request("POST", &uri, token, Some(body))).await;
    assert_eq!(status, StatusCode::OK, "{poll}");
    assert_eq!(poll["poll"]["ranked"], ranked);
    poll["id"].as_str().unwrap().to_owned()
}

async fn vote(w: &World, message_id: &str, token: &str, body: Value) -> StatusCode {
    let uri = format!("/messages/{message_id}/polls/vote");
    send(&w.app, request("PUT", &uri, token, Some(body)))
        .await
        .0
}

async fn read_poll(w: &World, token: &str) -> Value {
    let uri = format!("/channels/{}/messages", w.channel);
    let (_, listed) = send(&w.app, request("GET", &uri, token, None)).await;
    listed[0]["poll"].clone()
}

#[tokio::test]
async fn a_ranked_poll_transfers_votes_from_the_option_dropped_last() {
    let w = world().await;
    let mut tokens = Vec::new();
    for name in ["ana", "ben", "cy", "dee", "eli"] {
        tokens.push(member(&w.store, name).await.0);
    }
    let poll = create(&w, &tokens[0], &["beach", "city", "hills"], true).await;
    let rankings = [vec![0], vec![0], vec![1, 2], vec![2, 1], vec![2, 1]];
    for (token, ranking) in tokens.iter().zip(rankings) {
        let status = vote(&w, &poll, token, json!({ "ranking": ranking })).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }

    let read = read_poll(&w, &tokens[2]).await;
    assert_eq!(read["total_votes"], 5);
    assert_eq!(
        read["voted_option"], 1,
        "the first choice stands in for the vote"
    );
    assert_eq!(read["voted_ranking"], json!([1, 2]));
    let counts: Vec<i64> = read["options"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["votes"].as_i64().unwrap())
        .collect();
    assert_eq!(counts, [2, 1, 2], "option counts are first choices");
    assert_eq!(
        read["runoff"],
        json!({
            "rounds": [
                [{"position": 0, "votes": 2}, {"position": 1, "votes": 1}, {"position": 2, "votes": 2}],
                [{"position": 0, "votes": 2}, {"position": 2, "votes": 3}],
            ],
            "winner": 2,
        })
    );
}

#[tokio::test]
async fn ranking_again_replaces_the_whole_order() {
    let w = world().await;
    let (token, _) = member(&w.store, "ana").await;
    let poll = create(&w, &token, &["a", "b", "c"], true).await;
    let first = vote(&w, &poll, &token, json!({ "ranking": [0, 1, 2] })).await;
    assert_eq!(first, StatusCode::NO_CONTENT);
    let second = vote(&w, &poll, &token, json!({ "ranking": [2] })).await;
    assert_eq!(second, StatusCode::NO_CONTENT);

    let read = read_poll(&w, &token).await;
    assert_eq!(read["voted_ranking"], json!([2]));
    assert_eq!(read["total_votes"], 1);
    assert_eq!(read["options"][0]["votes"], 0);
    assert_eq!(read["runoff"]["winner"], 2);
}

#[tokio::test]
async fn a_ballot_must_fit_the_poll() {
    let w = world().await;
    let (token, _) = member(&w.store, "ana").await;
    let ranked = create(&w, &token, &["a", "b", "c"], true).await;
    let ordinary = create(&w, &token, &["a", "b"], false).await;

    let refused = [
        (&ranked, json!({ "option": 0 })),
        (&ordinary, json!({ "ranking": [0, 1] })),
        (&ranked, json!({ "option": 0, "ranking": [0] })),
        (&ranked, json!({})),
        (&ranked, json!({ "ranking": [] })),
        (&ranked, json!({ "ranking": [0, 0] })),
        (&ranked, json!({ "ranking": [0, 3] })),
    ];
    for (poll, body) in refused {
        assert_eq!(
            vote(&w, poll, &token, body.clone()).await,
            StatusCode::BAD_REQUEST,
            "{body} must be refused"
        );
    }
    assert_eq!(read_poll(&w, &token).await["total_votes"], 0);
    assert_eq!(
        vote(&w, &ordinary, &token, json!({ "option": 1 })).await,
        StatusCode::NO_CONTENT,
        "an ordinary poll still takes a plain option"
    );
}

async fn read_frame_of_type(ws: &mut WsClient, frame_type: &str) -> Value {
    for _ in 0..10 {
        let Some(Ok(WsMessage::Text(text))) = ws.next().await else {
            continue;
        };
        let frame: Value = serde_json::from_str(text.as_str()).unwrap();
        if frame["type"] == frame_type {
            return frame;
        }
    }
    panic!("did not see a `{frame_type}` frame within 10 frames");
}

#[tokio::test]
async fn the_vote_event_carries_the_runoff_and_never_the_voter() {
    let w = world().await;
    let (token, ticket) = member(&w.store, "ana").await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = http::router(w.state.clone());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    let hello = json!({ "type": "hello", "ticket": ticket, "protocol": 1 });
    ws.send(WsMessage::Text(hello.to_string())).await.unwrap();

    let poll = create(&w, &token, &["a", "b"], true).await;
    let created = read_frame_of_type(&mut ws, "message.created").await;
    assert_eq!(created["message"]["poll"]["voted_ranking"], Value::Null);
    assert_eq!(
        vote(&w, &poll, &token, json!({ "ranking": [1, 0] })).await,
        StatusCode::NO_CONTENT
    );

    let frame = read_frame_of_type(&mut ws, "poll.voted").await;
    let keys: Vec<&str> = frame
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys.iter()
            .copied()
            .collect::<std::collections::BTreeSet<_>>(),
        ["channel_id", "message_id", "options", "runoff", "type"].into(),
        "nothing in the event may say who ranked what"
    );
    assert_eq!(
        frame["runoff"],
        json!({ "rounds": [[{"position": 0, "votes": 0}, {"position": 1, "votes": 1}]], "winner": 1 })
    );
}
