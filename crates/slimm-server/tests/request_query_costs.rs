// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a handful of hot reads and writes cost in statements, asserted as a
//! shape (flat as the input grows) rather than as a number that rots.
//!
//! Counts sqlx's `sqlx::query` tracing events through a global subscriber; a
//! thread-local one reads zero, see `permissions_batch_cost.rs`. One global
//! recorder means one test, so this file is a single sequence of scenarios.

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::bot_ui::{UiEntry, UiRegistration};
use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{BotCommand, NewMessage, Store};
use tower::ServiceExt;
use tracing::Subscriber;
use tracing::field::{Field, Visit};
use tracing_subscriber::Registry;
use tracing_subscriber::layer::{Context, Layer, SubscriberExt};

mod support;

type Log = Arc<Mutex<Vec<String>>>;

struct RecordStatements(Log);

struct Statement(String);

impl Visit for Statement {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "db.statement" {
            self.0 = value.to_owned();
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "db.statement" && self.0.is_empty() {
            self.0 = format!("{value:?}");
        }
    }
}

impl<S: Subscriber> Layer<S> for RecordStatements {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != "sqlx::query" {
            return;
        }
        let mut statement = Statement(String::new());
        event.record(&mut statement);
        self.0.lock().unwrap().push(statement.0.trim().to_owned());
    }
}

/// The statements `work` ran, in order.
async fn statements_of<T>(
    log: &Log,
    work: impl std::future::Future<Output = T>,
) -> (Vec<String>, T) {
    let before = log.lock().unwrap().len();
    let out = work.await;
    let ran = log.lock().unwrap()[before..].to_vec();
    (ran, out)
}

async fn sync_statements(log: &Log, app: &axum::Router, token: &str, scopes: Vec<Value>) -> usize {
    let (ran, status) = statements_of(log, async {
        app.clone()
            .oneshot(
                Request::post("/sync")
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "scopes": scopes }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
    })
    .await;
    assert_eq!(status, 200);
    ran.len()
}

async fn add_bot(store: &Store, admin: UserId, name: &str) -> UserId {
    let bot = store
        .create_bot(name, name, Permissions::NONE, admin)
        .await
        .unwrap()
        .bot
        .user_id;
    let command = BotCommand {
        name: "ping".to_owned(),
        description: "pong".to_owned(),
        usage: None,
        permission: None,
        options: Vec::new(),
    };
    store
        .set_bot_commands(bot, &format!("{name}!"), &[command])
        .await
        .unwrap();
    let entry = UiEntry {
        id: "act".to_owned(),
        label: "Act".to_owned(),
        icon: None,
        permission: None,
        options: Vec::new(),
    };
    let ui = UiRegistration {
        message_menu: vec![entry],
        call_controls: Vec::new(),
    };
    store.set_bot_ui(bot, &ui).await.unwrap();
    bot
}

async fn channel_with_messages(store: &Store, name: &str, author: UserId) -> ChannelId {
    let channel = store.create_channel(name, "text").await.unwrap().id;
    store
        .send_message(NewMessage::plain(
            channel,
            author,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap();
    channel
}

#[tokio::test]
async fn hot_reads_and_writes_cost_a_flat_number_of_statements() {
    let log: Log = Arc::default();
    tracing::subscriber::set_global_default(
        Registry::default().with(RecordStatements(log.clone())),
    )
    .unwrap();
    let (store, _guard) = support::new_store("slimm-request-costs").await;
    let admin = support::app::register_account(&store, "admin").await;
    let general = support::app::general_channel_id(&store).await;
    let general = ChannelId(general.parse().unwrap());
    assert!(
        !log.lock().unwrap().is_empty(),
        "the recorder must see sqlx"
    );

    // A derived key is read from the database once, not on every module run.
    let (first, key) = statements_of(&log, store.module_caller_key()).await;
    let (again, same) = statements_of(&log, store.module_caller_key()).await;
    assert!(!first.is_empty());
    assert_eq!(key.unwrap(), same.unwrap());
    assert!(again.is_empty(), "a repeat read ran {again:?}");

    // Bot discovery asks for every bot's view access in one batch, however many bots there are.
    add_bot(&store, admin.id, "alpha").await;
    let (one_commands, _) =
        statements_of(&log, store.visible_bot_commands(general, Permissions::ALL)).await;
    let (one_ui, _) = statements_of(&log, store.visible_bot_ui(general, Permissions::ALL)).await;
    for name in ["bravo", "charlie", "delta", "echo", "foxtrot"] {
        add_bot(&store, admin.id, name).await;
    }
    let (six_commands, commands) =
        statements_of(&log, store.visible_bot_commands(general, Permissions::ALL)).await;
    let (six_ui, ui) = statements_of(&log, store.visible_bot_ui(general, Permissions::ALL)).await;
    assert_eq!(commands.unwrap().len(), 6);
    assert_eq!(ui.unwrap().len(), 6);
    assert_eq!(
        six_commands.len(),
        one_commands.len(),
        "bot-commands statements grew with the bot count"
    );
    assert_eq!(
        six_ui.len(),
        one_ui.len(),
        "bot-ui statements grew with the bot count"
    );

    // A message mentioning nobody takes no write turn, and clearing a stored mention still does.
    let message = store
        .send_message(NewMessage::plain(
            general,
            admin.id,
            MessageId::generate(),
            "hello",
        ))
        .await
        .unwrap()
        .message
        .id;
    let (ran, result) = statements_of(&log, store.set_message_mentions(message, &[], None)).await;
    result.unwrap();
    assert!(
        ran.iter().all(|sql| !sql.starts_with("DELETE")),
        "an empty mention set for a fresh message ran {ran:?}"
    );
    store
        .set_message_mentions(message, &[admin.id], None)
        .await
        .unwrap();
    store
        .set_message_mentions(message, &[], None)
        .await
        .unwrap();
    let still = store
        .mentioned_messages_for(admin.id, &[message])
        .await
        .unwrap();
    assert!(
        still.is_empty(),
        "an edit that drops every mention clears them"
    );

    // A reconnect with every cursor current costs the same for 3 channels as for 12.
    let mut channels = vec![general];
    for n in 0..11 {
        channels.push(channel_with_messages(&store, &format!("room-{n}"), admin.id).await);
    }
    let mut current = Vec::new();
    for channel in &channels {
        current.push(json!({
            "channel_id": channel.to_string(),
            "after_seq": store.latest_message_seq(*channel).await.unwrap(),
            "after_op_seq": store.latest_message_op_seq(*channel).await.unwrap(),
        }));
    }
    let app = support::app::app(store.clone());
    sync_statements(&log, &app, &admin.token, current[..1].to_vec()).await;
    let few = sync_statements(&log, &app, &admin.token, current[..3].to_vec()).await;
    let many = sync_statements(&log, &app, &admin.token, current).await;
    assert_eq!(many, few, "sync grew from {few} to {many} statements");
}
