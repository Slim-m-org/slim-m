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
use sqlx::Connection;
use tower::ServiceExt;

use crate::support;
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

/// MANAGE_SERVER alone lets a module into no channel its holder could not post in themselves.
#[tokio::test]
async fn a_manager_cannot_send_a_module_into_a_channel_they_cannot_see_or_post_in() {
    let w = world("slimm-modsched-hidden").await;
    let role = w
        .store
        .create_role("managers", Permissions::MANAGE_SERVER, false);
    w.store
        .assign_role(w.user.id, role.await.unwrap())
        .await
        .unwrap();
    let staff = w.store.create_channel("staff", "text").await.unwrap().id;
    let news = w.store.create_channel("news", "text").await.unwrap().id;
    let (view, send) = (Permissions::VIEW_CHANNEL, Permissions::SEND_MESSAGES);
    let none = Permissions::NONE;
    w.store
        .set_role_overwrite(staff, w.everyone, none, view)
        .await
        .unwrap();
    w.store
        .set_role_overwrite(news, w.everyone, none, send)
        .await
        .unwrap();
    ticker(&w, &staff.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();

    let hidden = set_channel(&w, &w.token, "ticker", Some(staff.to_string())).await;
    let nowhere = Some(uuid::Uuid::now_v7().to_string());
    let unknown = set_channel(&w, &w.token, "ticker", nowhere).await;
    assert_eq!(hidden.0, StatusCode::BAD_REQUEST, "{}", hidden.1);
    assert_eq!(hidden, unknown, "a hidden channel answers like no channel");
    let read_only = set_channel(&w, &w.token, "ticker", Some(news.to_string())).await;
    assert_eq!(read_only.0, StatusCode::FORBIDDEN, "{}", read_only.1);

    for (channel, kept_out_of) in [(staff, view), (news, send)] {
        let let_in = w.store.has_permission(bot, channel, kept_out_of).await;
        assert!(!let_in.unwrap(), "the module was let into {channel}");
    }
    let module = w.store.installed_module("ticker").await.unwrap().unwrap();
    assert_eq!(module.schedule_channel_id, None);
    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 0);
}

#[tokio::test]
async fn removing_the_module_s_principal_stops_its_scheduled_posts() {
    let w = world("slimm-modsched-removed").await;
    let token = admin_token(&w).await;
    let feed = w.store.create_channel("feed", "text").await.unwrap();
    ticker(&w, &feed.id.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    set_channel(&w, &token, "ticker", Some(feed.id.to_string())).await;
    let removal = Request::builder()
        .method("PUT")
        .uri(format!("/members/{bot}/removal"))
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();
    let response = w.router.clone().oneshot(removal).await.unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);

    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 0);

    let landed = w.store.list_messages(feed.id, None, 10).await.unwrap();
    assert!(landed.is_empty(), "a removed principal posts nothing");
}

async fn open_feed(w: &World, name: &str) -> slimm_server::ids::ChannelId {
    let feed = w.store.create_channel(name, "text").await.unwrap();
    w.store
        .set_role_overwrite(
            feed.id,
            w.everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    feed.id
}

#[tokio::test]
async fn moving_the_channel_keeps_what_an_admin_set_for_the_module_elsewhere() {
    let w = world("slimm-modsched-keeps").await;
    let token = admin_token(&w).await;
    let (first, second) = (open_feed(&w, "first").await, open_feed(&w, "second").await);
    ticker(&w, &first.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    let post = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    let react = Permissions::ADD_REACTIONS;
    w.store
        .set_member_overwrite(second, bot, react, Permissions::NONE)
        .await
        .unwrap();
    let (status, _) = set_channel(&w, &token, "ticker", Some(first.to_string())).await;
    assert_eq!(status, StatusCode::OK);
    w.store
        .set_member_overwrite(first, bot, post.union(react), Permissions::NONE)
        .await
        .unwrap();

    let (status, _) = set_channel(&w, &token, "ticker", Some(second.to_string())).await;
    assert_eq!(status, StatusCode::OK);
    let on_second = w
        .store
        .overwrite_for(second, "member", bot.0)
        .await
        .unwrap();
    assert_eq!(on_second, Some((post.union(react), Permissions::NONE)));
    let on_first = w.store.overwrite_for(first, "member", bot.0).await.unwrap();
    assert!(
        on_first.is_some(),
        "an overwrite changed by hand is left alone"
    );
}

#[tokio::test]
async fn a_deny_set_for_the_module_blocks_the_move_and_changes_nothing() {
    let w = world("slimm-modsched-deny").await;
    let token = admin_token(&w).await;
    let (first, second) = (open_feed(&w, "first").await, open_feed(&w, "second").await);
    ticker(&w, &first.to_string(), &["schedule", "message.post"]).await;
    let bot = w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    set_channel(&w, &token, "ticker", Some(first.to_string())).await;
    let denied = Permissions::SEND_MESSAGES;
    w.store
        .set_member_overwrite(second, bot, Permissions::NONE, denied)
        .await
        .unwrap();

    let (status, _) = set_channel(&w, &token, "ticker", Some(second.to_string())).await;
    assert_eq!(status, StatusCode::CONFLICT);
    let on_second = w
        .store
        .overwrite_for(second, "member", bot.0)
        .await
        .unwrap();
    assert_eq!(on_second, Some((Permissions::NONE, denied)));
    let module = w.store.installed_module("ticker").await.unwrap().unwrap();
    assert_eq!(module.schedule_channel_id, Some(first));
    let on_first = w.store.overwrite_for(first, "member", bot.0).await.unwrap();
    assert!(
        on_first.is_some(),
        "the old grant stays while the module still points at it"
    );
}

#[tokio::test]
async fn a_clock_moved_backwards_still_runs_the_schedule() {
    let w = world("slimm-modsched-clock").await;
    let token = admin_token(&w).await;
    let feed = open_feed(&w, "feed").await;
    ticker(&w, &feed.to_string(), &["schedule", "message.post"]).await;
    w.store.ensure_module_bot("ticker", "Ticker").await.unwrap();
    set_channel(&w, &token, "ticker", Some(feed.to_string())).await;
    w.store
        .record_module_schedule_run("ticker", "run", 10_000 * MINUTE)
        .await
        .unwrap();

    assert_eq!(
        run_scheduled_modules(&w.state, 5 * MINUTE).await.unwrap(),
        1
    );
    let runs = w.store.module_schedule_runs("ticker").await.unwrap();
    assert_eq!(
        runs.get("run"),
        Some(&(5 * MINUTE)),
        "the stored time follows the clock back"
    );
}

#[tokio::test]
async fn one_module_failing_its_store_write_does_not_skip_the_rest() {
    let w = world("slimm-modsched-isolated").await;
    let token = admin_token(&w).await;
    let feed = open_feed(&w, "feed").await;
    w.install(Install {
        id: "aaa-broken",
        wasm: host_call_loop_wasm(&post_request(&feed.to_string(), "never"), 1),
        declared: &["schedule", "message.post"],
        approved_host: &["schedule", "message.post"],
    })
    .await;
    w.store
        .set_module_schedules(
            "aaa-broken",
            &[ModuleSchedule {
                command: "run".into(),
                every_minutes: 5,
            }],
        )
        .await
        .unwrap();
    ticker(&w, &feed.to_string(), &["schedule", "message.post"]).await;
    for id in ["aaa-broken", "ticker"] {
        w.store.ensure_module_bot(id, id).await.unwrap();
        set_channel(&w, &token, id, Some(feed.to_string())).await;
    }
    let url = format!("sqlite://{}", w.db_path);
    let mut conn = sqlx::sqlite::SqliteConnection::connect(&url).await.unwrap();
    sqlx::query(
        "CREATE TRIGGER refuse_broken BEFORE INSERT ON module_schedule_runs
         WHEN NEW.module_id = 'aaa-broken' BEGIN SELECT RAISE(ABORT, 'broken'); END",
    )
    .execute(&mut conn)
    .await
    .unwrap();

    assert_eq!(run_scheduled_modules(&w.state, 0).await.unwrap(), 1);
    let landed = w.store.list_messages(feed, None, 10).await.unwrap();
    assert_eq!(landed.len(), 1, "the module after the broken one still ran");
}
