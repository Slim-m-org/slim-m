// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Search finds a word inside text written without spaces, refuses raw
//! prefix syntax that would scan the whole index, scopes its cursor to the
//! caller's channels, and reads the text a forward, poll or embed carries.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{MessageSearchFilters, NewEmbed, NewMessage, SearchError, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;

use crate::message_search::fixtures::*;

async fn get(app: &axum::Router, token: &str, uri: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(request("GET", uri, Some(token), None))
        .await
        .unwrap();
    let status = response.status();
    (status, json_body(response).await)
}

async fn contents(app: &axum::Router, token: &str, q: &str) -> Vec<String> {
    let (status, body) = get(app, token, &format!("/search/messages?q={q}")).await;
    assert_eq!(status, StatusCode::OK, "q={q}");
    body.as_array()
        .unwrap()
        .iter()
        .map(|m| m["content"].as_str().unwrap().to_owned())
        .collect()
}

async fn world() -> (
    Store,
    SqlitePool,
    axum::Router,
    String,
    ChannelId,
    crate::support::TestDbGuard,
) {
    let (store, pool, guard) = new_store_with_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    (store, pool, app, token, channel, guard)
}

#[tokio::test]
async fn a_word_inside_cjk_and_thai_text_is_found() {
    let (_store, _pool, app, token, channel, _guard) = world().await;
    let id = channel.to_string();
    for text in [
        "你好世界朋友",
        "今日はいい天気です",
        "สวัสดีครับเพื่อนๆ",
        "latin only",
    ] {
        send(&app, &id, &token, text).await;
    }
    assert_eq!(contents(&app, &token, "世界").await, ["你好世界朋友"]);
    assert_eq!(contents(&app, &token, "世界朋").await, ["你好世界朋友"]);
    assert_eq!(contents(&app, &token, "天気").await, ["今日はいい天気です"]);
    assert_eq!(contents(&app, &token, "ครับเพื่อน").await, ["สวัสดีครับเพื่อนๆ"]);
    assert!(contents(&app, &token, "世界末").await.is_empty());
}

#[tokio::test]
async fn an_edited_cjk_message_is_reindexed() {
    let (_store, pool, app, token, channel, _guard) = world().await;
    let sent = send(&app, &channel.to_string(), &token, "你好世界朋友").await;
    sqlx::query("UPDATE messages SET content = ? WHERE id = ?")
        .bind("再见月亮朋友")
        .bind(MessageId(sent["id"].as_str().unwrap().parse().unwrap()))
        .execute(&pool)
        .await
        .unwrap();
    assert!(contents(&app, &token, "世界").await.is_empty());
    assert_eq!(contents(&app, &token, "月亮").await, ["再见月亮朋友"]);
}

#[tokio::test]
async fn a_one_letter_prefix_term_in_raw_syntax_is_not_scanned_as_a_prefix() {
    let (_store, _pool, app, token, channel, _guard) = world().await;
    let id = channel.to_string();
    send(&app, &id, &token, "apple elk").await;
    send(&app, &id, &token, "a e").await;
    let found = contents(&app, &token, "a*%20e*").await;
    assert_eq!(found, ["a e"], "the starred letters match whole words only");
    let many = (b'a'..=b'z')
        .map(|c| format!("{}{}*", c as char, c as char))
        .collect::<Vec<_>>()
        .join("%20OR%20");
    let (status, _) = get(&app, &token, &format!("/search/messages?q={many}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(contents(&app, &token, "app*").await, ["apple elk"]);
}

#[tokio::test]
async fn a_column_filter_is_not_a_bad_request() {
    let (_store, _pool, app, token, channel, _guard) = world().await;
    send(&app, &channel.to_string(), &token, "windows install").await;
    let (status, _) = get(&app, &token, "/search/messages?q=content:win").await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn a_cursor_from_a_channel_the_caller_cannot_view_reads_as_missing() {
    let (store, _pool, guard) = new_store_with_pool().await;
    let _guard = guard;
    let everyone = store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap().id;
    let vault = store.create_channel("vault", "text").await.unwrap();
    store
        .set_role_overwrite(
            vault.id,
            everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let token = register(&store, "alice").await;
    send(&app, &channel.to_string(), &token, "herons here").await;
    let ghost = store
        .create_account("ghost", "ghost", "not-a-real-hash")
        .await
        .unwrap();
    let hidden = MessageId::generate();
    store
        .send_message(NewMessage::plain(
            vault.id,
            ghost.id,
            hidden,
            "herons there",
        ))
        .await
        .unwrap();
    let (status, _) = get(
        &app,
        &token,
        &format!("/search/messages?q=herons&before_id={hidden}"),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let unknown = MessageId::generate();
    let (status, _) = get(
        &app,
        &token,
        &format!("/search/messages?q=herons&before_id={unknown}"),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn forward_poll_and_embed_text_is_searchable() {
    let (store, pool, app, token, channel, _guard) = world().await;
    let author = store
        .create_account("bot", "bot", "not-a-real-hash")
        .await
        .unwrap();
    let mut planted = Vec::new();
    for _ in 0..3 {
        let id = MessageId::generate();
        store
            .send_message(NewMessage::plain(channel, author.id, id, ""))
            .await
            .unwrap();
        planted.push(id);
    }
    sqlx::query(
        "INSERT INTO message_forwards
             (message_id, origin_message_id, origin_channel_id, origin_created_at, origin_content)
         VALUES (?, ?, ?, 1, 'lighthouse maintenance notice')",
    )
    .bind(planted[0])
    .bind(MessageId::generate())
    .bind(channel)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO polls (message_id, channel_id, question, created_at) VALUES (?, ?, 'favourite pangolin?', 1)")
        .bind(planted[1])
        .bind(channel)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO poll_options (message_id, position, label) VALUES (?, 0, 'armadillo')",
    )
    .bind(planted[1])
    .execute(&pool)
    .await
    .unwrap();
    let embed = NewEmbed {
        title: Some("Downloaded: Quokka Season 2".into()),
        ..NewEmbed::default()
    };
    store
        .replace_message_embeds(planted[2], &[embed])
        .await
        .unwrap();

    for (q, expected) in [
        ("lighthouse", planted[0]),
        ("pangolin", planted[1]),
        ("armadillo", planted[1]),
        ("quokka", planted[2]),
    ] {
        let (status, body) = get(&app, &token, &format!("/search/messages?q={q}")).await;
        assert_eq!(status, StatusCode::OK);
        let ids: Vec<&str> = body
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, [expected.to_string()], "q={q}");
    }

    store.replace_message_embeds(planted[2], &[]).await.unwrap();
    assert!(contents(&app, &token, "quokka").await.is_empty());
    sqlx::query("UPDATE message_forwards SET origin_content = '' WHERE message_id = ?")
        .bind(planted[0])
        .execute(&pool)
        .await
        .unwrap();
    assert!(contents(&app, &token, "lighthouse").await.is_empty());
}

#[tokio::test]
async fn the_store_refuses_a_prefix_flood_before_running_it() {
    let (store, _pool, _app, _token, channel, _guard) = world().await;
    let result = store
        .search_messages(
            &[channel],
            Some("a* OR b* OR c*"),
            &MessageSearchFilters::default(),
            None,
            10,
        )
        .await;
    assert!(matches!(result, Err(SearchError::InvalidQuery)));
}
