// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Two ways a module touches people it does not own: the principal it posts
//! as on a schedule (removed with the module), and the text a slash command
//! prints (posted with the module's name on it, never as the member's own).

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::ModuleSchedule;
use tower::ServiceExt;

mod support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::{canned_ok_wasm, canned_raw_wasm};

async fn admin_token(w: &World) -> String {
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = w.store.create_user("root", "Root").await.unwrap();
    w.store.assign_role(admin.id, role).await.unwrap();
    w.store
        .open_session(admin.id, "laptop")
        .await
        .unwrap()
        .access_token
}

async fn send(w: &World, method: &str, uri: &str, token: &str, body: Value) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let response = w.router.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn post_output(
    w: &World,
    module: &str,
    channel: ChannelId,
    extra: Value,
) -> (StatusCode, Value) {
    let mut body = json!({ "input": "go", "channel_id": channel.to_string(), "post_output": true });
    body.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    send(
        w,
        "POST",
        &format!("/modules/{module}/commands/run"),
        &w.token,
        body,
    )
    .await
}

#[tokio::test]
async fn uninstalling_removes_the_principal_and_its_channel_overwrite() {
    let w = world("slimm-modprin-uninstall").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    w.install(Install {
        id: "ticker",
        wasm: canned_ok_wasm("tick"),
        declared: &["schedule"],
        approved_host: &["schedule"],
    })
    .await;
    w.store
        .set_module_schedules(
            "ticker",
            &[ModuleSchedule {
                command: "run".into(),
                every_minutes: 5,
            }],
        )
        .await
        .unwrap();
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    let (status, _) = send(
        &w,
        "PUT",
        "/space/dock/modules/ticker/schedule-channel",
        &token,
        json!({ "channel_id": feed.id.to_string() }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let overwrites = w.store.channel_overwrites(feed.id).await.unwrap();
    assert!(
        overwrites.iter().any(|o| o.target_id == bot.0),
        "the channel lists the principal"
    );

    let (status, _) = send(
        &w,
        "DELETE",
        "/space/dock/modules/ticker/install",
        &token,
        Value::Null,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert!(
        w.store.user_profile(bot).await.unwrap().is_none(),
        "no orphan principal"
    );
    let overwrites = w.store.channel_overwrites(feed.id).await.unwrap();
    assert!(
        overwrites.iter().all(|o| o.target_id != bot.0),
        "the channel still lists the module's principal"
    );
}

#[tokio::test]
async fn reinstalling_mints_exactly_one_live_principal() {
    let w = world("slimm-modprin-reinstall").await;
    let token = admin_token(&w).await;
    let install = || {
        w.install(Install {
            id: "ticker",
            wasm: canned_ok_wasm("tick"),
            declared: &["schedule"],
            approved_host: &["schedule"],
        })
    };
    install().await;
    let first = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    assert_eq!(
        w.store.ensure_module_bot("ticker", "Ticker").await.unwrap(),
        first
    );
    send(
        &w,
        "DELETE",
        "/space/dock/modules/ticker/install",
        &token,
        Value::Null,
    )
    .await;
    install().await;
    let second = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    assert_ne!(first, second);
    assert!(w.store.user_profile(first).await.unwrap().is_none());
    assert!(w.store.user_profile(second).await.unwrap().is_some());
}

#[tokio::test]
async fn slash_output_is_posted_as_the_member_but_labelled_as_the_modules() {
    let w = world("slimm-modout-post").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    w.install(Install {
        id: "printer",
        wasm: canned_ok_wasm("hello from a module"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (status, body) = post_output(&w, "printer", channel.id, json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(true));
    assert!(body.get("output").is_none(), "{body}");

    let id = slimm_server::ids::MessageId(body["message_id"].as_str().unwrap().parse().unwrap());
    let message = w
        .store
        .message_including_deleted(id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(message.author_id, Some(w.user.id));
    assert_eq!(message.content, "hello from a module");
    let embeds = w.store.embeds_for_messages(&[id]).await.unwrap();
    assert_eq!(
        embeds[0].1[0].footer_text.as_deref(),
        Some("via Scorekeeper")
    );
}

#[tokio::test]
async fn slash_output_replying_keeps_the_reply_and_a_failed_run_posts_nothing() {
    let w = world("slimm-modout-reply").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let parent = slimm_server::ids::MessageId::generate();
    w.store
        .send_message(slimm_server::store::NewMessage::plain(
            channel.id, w.user.id, parent, "question",
        ))
        .await
        .unwrap();
    w.install(Install {
        id: "printer",
        wasm: canned_ok_wasm("answer"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (_, body) = post_output(
        &w,
        "printer",
        channel.id,
        json!({ "reply_to_id": parent.to_string() }),
    )
    .await;
    let id = slimm_server::ids::MessageId(body["message_id"].as_str().unwrap().parse().unwrap());
    let message = w
        .store
        .message_including_deleted(id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(message.reply_to_id, Some(parent));

    w.install(Install {
        id: "failing",
        wasm: canned_raw_wasm(br#"{"ok":false,"error":"bad input"}"#),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (_, failed) = post_output(&w, "failing", channel.id, json!({})).await;
    assert_eq!(failed["ok"], json!(false));
    assert_eq!(failed["error"], json!("bad input"));
    assert_eq!(
        w.store
            .list_messages(channel.id, None, 10)
            .await
            .unwrap()
            .len(),
        2
    );
}

#[tokio::test]
async fn slash_output_cannot_be_posted_where_the_member_cannot_post() {
    let w = world("slimm-modout-denied").await;
    let news = w.store.create_channel("news", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            news.id,
            w.everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    w.install(Install {
        id: "printer",
        wasm: canned_ok_wasm("sneaky"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    let (status, body) = post_output(&w, "printer", news.id, json!({})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ok"], json!(false), "{body}");
    assert!(
        w.store
            .list_messages(news.id, None, 10)
            .await
            .unwrap()
            .is_empty()
    );
}
