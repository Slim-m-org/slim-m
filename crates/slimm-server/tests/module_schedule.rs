// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `schedule` capability end to end: a module the admin approved and
//! gave a channel runs its command on its interval with nobody invoking it,
//! posts there as its own principal, and does nothing without all three.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::run_scheduled_modules;
use slimm_server::permissions::Permissions;
use slimm_server::store::ModuleSchedule;
use tower::ServiceExt;

mod support;
use support::module_world::{Install, World, post_request, world};
use support::wasm_fixtures::host_call_loop_wasm;

const MINUTE: i64 = 60_000;

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

async fn set_channel(
    w: &World,
    token: &str,
    module: &str,
    channel: Option<String>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method("PUT")
        .uri(format!("/space/dock/modules/{module}/schedule-channel"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(json!({ "channel_id": channel }).to_string()))
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

/// A `ticker` module whose `run` posts "tick" into `channel`, scheduled every 5 minutes.
async fn ticker(w: &World, channel: &str, approved: &[&str]) {
    w.install(Install {
        id: "ticker",
        wasm: host_call_loop_wasm(&post_request(channel, "tick"), 1),
        declared: &["schedule", "message.post"],
        approved_host: approved,
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
}

#[tokio::test]
async fn an_approved_schedule_posts_as_the_module_on_its_interval() {
    let w = world("slimm-modsched-runs").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            feed.id,
            w.everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    ticker(&w, &feed.id.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();

    assert_eq!(
        run_scheduled_modules(&w.state, 0).await.unwrap(),
        0,
        "no channel yet"
    );
    let (status, module) = set_channel(&w, &token, "ticker", Some(feed.id.to_string())).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(module["schedule_channel_id"], json!(feed.id.to_string()));

    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 1);
    let landed = w.store.list_messages(feed.id, None, 10).await.unwrap();
    assert_eq!(landed.len(), 1);
    assert_eq!(
        landed[0].author_id,
        Some(bot),
        "posted as the module, not a person"
    );
    assert_eq!(landed[0].content, "tick");
    let origin = w.store.module_origin(landed[0].id).await.unwrap().unwrap();
    assert_eq!(
        (origin.module_id.as_str(), origin.background),
        ("ticker", true),
        "a run nobody invoked is marked as the module's own"
    );

    assert_eq!(
        run_scheduled_modules(&w.state, 5 * MINUTE - 1)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        run_scheduled_modules(&w.state, 5 * MINUTE).await.unwrap(),
        1
    );
    assert_eq!(
        w.store
            .list_messages(feed.id, None, 10)
            .await
            .unwrap()
            .len(),
        2
    );
}

#[tokio::test]
async fn moving_the_channel_takes_the_old_one_away() {
    let w = world("slimm-modsched-move").await;
    let token = admin_token(&w).await;
    let first = w.store.create_channel("first", "text").await.unwrap();
    let second = w.store.create_channel("second", "text").await.unwrap();
    for channel in [first.id, second.id] {
        w.store
            .set_role_overwrite(
                channel,
                w.everyone,
                Permissions::NONE,
                Permissions::SEND_MESSAGES,
            )
            .await
            .unwrap();
    }
    ticker(&w, &first.id.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    let post = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    set_channel(&w, &token, "ticker", Some(first.id.to_string())).await;
    assert!(w.store.has_permission(bot, first.id, post).await.unwrap());

    set_channel(&w, &token, "ticker", Some(second.id.to_string())).await;
    assert!(!w.store.has_permission(bot, first.id, post).await.unwrap());
    assert!(w.store.has_permission(bot, second.id, post).await.unwrap());
}

#[tokio::test]
async fn nothing_runs_without_the_approval_while_disabled_or_once_deleted() {
    let w = world("slimm-modsched-gates").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    ticker(&w, &feed.id.to_string(), &["schedule", "message.post"]).await;
    w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    // Withdrawn after the principal exists: it stays, the approval does not.
    ticker(&w, &feed.id.to_string(), &["message.post"]).await;
    let (status, _) = set_channel(&w, &token, "ticker", Some(feed.id.to_string())).await;
    assert_eq!(status, StatusCode::CONFLICT, "schedule is not approved");

    ticker(&w, &feed.id.to_string(), &["schedule", "message.post"]).await;
    set_channel(&w, &token, "ticker", Some(feed.id.to_string())).await;
    w.store.set_module_enabled("ticker", false).await.unwrap();
    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 0);

    w.store.set_module_enabled("ticker", true).await.unwrap();
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    w.store.delete_account(bot).await.unwrap();
    assert_eq!(
        run_scheduled_modules(&w.state, 0).await.unwrap(),
        0,
        "a deleted principal posts nothing"
    );
}

#[tokio::test]
async fn only_an_admin_picks_the_channel_and_only_a_text_one() {
    let w = world("slimm-modsched-route").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    let voice = w.store.create_channel("lounge", "voice").await.unwrap();
    ticker(&w, &feed.id.to_string(), &["schedule"]).await;
    w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();

    let (status, _) = set_channel(&w, &w.token, "ticker", Some(feed.id.to_string())).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = set_channel(&w, &token, "ticker", Some(voice.id.to_string())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, cleared) = set_channel(&w, &token, "ticker", None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(cleared.get("schedule_channel_id").is_none());
}
