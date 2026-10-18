// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Space usage analytics: off by default, and the whole feature - derived
//! counts included - answers nothing while the toggle is off. See
//! `docs/decisions/0008-space-analytics.md` and `store/analytics.rs`.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{NewMessage, Store};
use sqlx::SqlitePool;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, request_authed as request};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_millis() as i64
}

/// Also returns a clone of the pool, since `Store` does not expose its own:
/// a couple of tests below reach past the store's public API to backdate a
/// row directly, the only way to exercise the retention prune without
/// waiting out the real window.
async fn store(name: &str) -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

/// An administrator plus an ordinary member: MANAGE_SERVER on one, nothing
/// beyond @everyone on the other.
async fn deployment(s: &Store) -> (slimm_server::store::User, slimm_server::store::User) {
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let admin_role = s
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    let admin = s.create_user("root", "Root").await.unwrap();
    s.assign_role(admin.id, admin_role).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    (admin, member)
}

#[tokio::test]
async fn analytics_is_off_by_default() {
    let (s, _pool, _guard) = store("slimm-analytics-default").await;
    assert!(!s.analytics_enabled().await.unwrap());
}

#[tokio::test]
async fn the_toggle_round_trips() {
    let (s, _pool, _guard) = store("slimm-analytics-toggle").await;
    s.set_analytics_enabled(true).await.unwrap();
    assert!(s.analytics_enabled().await.unwrap());
    s.set_analytics_enabled(false).await.unwrap();
    assert!(!s.analytics_enabled().await.unwrap());
}

/// The load-bearing property: a deployment that never turned analytics on
/// answers with no stats over HTTP, even though the messages the stats would
/// summarize already exist. Mutation-tested by deleting the early return in
/// `http::analytics::current_analytics`, which turns this into the only
/// failing test.
#[tokio::test]
async fn a_disabled_deployment_answers_with_no_stats_even_though_messages_exist() {
    let (s, _pool, _guard) = store("slimm-analytics-disabled").await;
    let (admin, member) = deployment(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.send_message(NewMessage::plain(
        channel.id,
        member.id,
        MessageId::generate(),
        "hello",
    ))
    .await
    .unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["enabled"], json!(false));
    assert!(body["stats"].is_null());
}

/// Once on, the derived counts are real rather than placeholders: seeded
/// state (a channel, two messages, one of them deleted) round-trips through
/// the whole store-to-DTO path.
#[tokio::test]
async fn an_enabled_deployment_reports_the_real_counts() {
    let (s, _pool, _guard) = store("slimm-analytics-enabled").await;
    let (admin, member) = deployment(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.send_message(NewMessage::plain(
        channel.id,
        member.id,
        MessageId::generate(),
        "kept",
    ))
    .await
    .unwrap();
    let removed_id = MessageId::generate();
    s.send_message(NewMessage::plain(channel.id, member.id, removed_id, "gone"))
        .await
        .unwrap();
    s.delete_message(removed_id, member.id).await.unwrap();

    s.set_analytics_enabled(true).await.unwrap();
    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = json_body(response).await;
    assert_eq!(body["enabled"], json!(true));
    let stats = &body["stats"];
    assert_eq!(stats["total_messages"], json!(1));
    assert_eq!(stats["member_count"], json!(2));
    assert_eq!(stats["channel_count"], json!(1));
    let hours_sum: i64 = stats["active_hours"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_i64().unwrap())
        .sum();
    assert_eq!(hours_sum, 1);
}

/// A DM never counts as a Space channel: seeded alongside the real one so a
/// query missing the `kind != 'dm'` exclusion would inflate the count and
/// fail this specifically rather than any of the tests above.
#[tokio::test]
async fn channel_count_excludes_dm_channels() {
    let (s, _pool, _guard) = store("slimm-analytics-dm").await;
    let (admin, member) = deployment(&s).await;
    s.create_channel("general", "text").await.unwrap();
    s.open_dm(admin.id, member.id).await.unwrap();

    s.set_analytics_enabled(true).await.unwrap();
    let stats = s.analytics_stats().await.unwrap();
    assert_eq!(stats.channel_count, 1);
}

/// The privacy line this feature is built against, checked structurally
/// against the serialized wire shape rather than the Rust struct: an
/// aggregate active-hours histogram must never carry anything that names an
/// individual member, at any depth. Mirrors `message_ops`'s
/// `no_op_carries_an_actor_on_any_kind`.
///
/// Scoped to `body["stats"]` rather than the whole response: `member_storage`
/// is a deliberate exception to this rule (see
/// `member_storage_is_a_sibling_of_stats_and_names_its_members` below), and
/// checking the whole body here would make this test fail the moment that
/// field exists, for the one field the project chose to let name a member.
#[tokio::test]
async fn the_analytics_response_never_names_a_member() {
    let (s, _pool, _guard) = store("slimm-analytics-privacy").await;
    let (admin, member) = deployment(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.send_message(NewMessage::plain(
        channel.id,
        member.id,
        MessageId::generate(),
        "hi",
    ))
    .await
    .unwrap();
    s.set_analytics_enabled(true).await.unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let admin_id_str = admin.id.to_string();
    let member_id_str = member.id.to_string();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    let body = json_body(response).await;
    let text = body["stats"].to_string();
    assert!(!text.contains(&admin_id_str));
    assert!(!text.contains(&member_id_str));
    assert!(!text.contains("nia"));
    assert!(!text.contains("Nia"));
}

/// The other half of the same line: `member_storage` is where a member id
/// deliberately does appear, as its own sibling field rather than folded
/// into `stats` - storage stewardship, not usage surveillance. See
/// `docs/decisions/0008-space-analytics.md`.
#[tokio::test]
async fn member_storage_is_a_sibling_of_stats_and_names_its_members() {
    let (s, _pool, _guard) = store("slimm-analytics-member-storage").await;
    let (admin, member) = deployment(&s).await;
    s.store_attachment(&[1; 32], 4_000, "image/png", "a.png", Some(admin.id))
        .await
        .unwrap();
    s.store_attachment(&[2; 32], 1_000, "image/png", "b.png", Some(member.id))
        .await
        .unwrap();
    s.set_analytics_enabled(true).await.unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    let body = json_body(response).await;
    let storage = body["member_storage"].as_array().unwrap();
    assert_eq!(storage.len(), 2);
    // Heaviest first.
    assert_eq!(storage[0]["user_id"], json!(admin.id.to_string()));
    assert_eq!(storage[0]["attachment_bytes"], json!(4_000));
    assert_eq!(storage[1]["user_id"], json!(member.id.to_string()));
    assert_eq!(storage[1]["attachment_bytes"], json!(1_000));
    // Never nested inside the never-names-a-member block.
    assert!(body["stats"]["member_storage"].is_null());
}

/// The same bytes uploaded by two different members charges each the full
/// size: content addressing dedupes disk use, not per-member attribution.
#[tokio::test]
async fn identical_bytes_uploaded_twice_charges_both_uploaders_in_full() {
    let (s, _pool, _guard) = store("slimm-analytics-member-storage-dedupe").await;
    let (admin, member) = deployment(&s).await;
    s.store_attachment(&[9; 32], 500, "image/png", "same.png", Some(admin.id))
        .await
        .unwrap();
    s.store_attachment(&[9; 32], 500, "image/png", "same.png", Some(member.id))
        .await
        .unwrap();
    s.set_analytics_enabled(true).await.unwrap();

    let storage = s.member_attachment_bytes().await.unwrap();
    assert_eq!(storage.len(), 2);
    assert!(storage.iter().all(|m| m.attachment_bytes == 500));
}

/// `member_storage` follows the same "off means the feature does not run"
/// rule as `stats`.
#[tokio::test]
async fn member_storage_is_absent_while_disabled() {
    let (s, _pool, _guard) = store("slimm-analytics-member-storage-off").await;
    let (admin, _member) = deployment(&s).await;
    s.store_attachment(&[3; 32], 200, "image/png", "c.png", Some(admin.id))
        .await
        .unwrap();

    let session = s.open_session(admin.id, "laptop").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    let body = json_body(response).await;
    assert!(body["member_storage"].is_null());
}

/// A caller without MANAGE_SERVER is refused the same way `/space/settings`
/// already refuses one, gated identically rather than left open by omission.
#[tokio::test]
async fn reading_analytics_requires_manage_server() {
    let (s, _pool, _guard) = store("slimm-analytics-forbidden").await;
    let (_admin, member) = deployment(&s).await;
    let session = s.open_session(member.id, "phone").await.unwrap();
    let router = app(s);
    let response = router
        .oneshot(request(
            "GET",
            "/space/analytics",
            &session.access_token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

/// Two samples requested back to back collapse into one row; the minimum gap
/// is what stops every screen view from growing the table.
#[tokio::test]
async fn a_second_sample_within_the_minimum_gap_is_not_recorded() {
    let (s, _pool, _guard) = store("slimm-analytics-gap").await;
    s.maybe_record_metrics_sample(1_000).await.unwrap();
    s.maybe_record_metrics_sample(2_000).await.unwrap();
    let stats = s.analytics_stats().await.unwrap();
    assert_eq!(stats.memory_samples.len(), 1);
    assert_eq!(stats.memory_samples[0].rss_bytes, 1_000);
}

/// `active_hours` and `memory_samples` filter a raw `>= window_start`
/// timestamp rather than group by calendar date the way `messages_by_day`
/// does, so they must not reuse that series's `-1`-adjusted start: a message
/// and a memory sample dated 30 days ago plus an hour - inside the true
/// window, but outside a 29-day one - must both still be counted. Mutation-
/// tested by restoring the single shared `window_start` in
/// `Store::analytics_stats`, which drops both counts to zero.
#[tokio::test]
async fn active_hours_and_memory_samples_cover_the_full_thirtieth_day() {
    let (s, pool, _guard) = store("slimm-analytics-full-window").await;
    let (_admin, member) = deployment(&s).await;
    let channel = s.create_channel("general", "text").await.unwrap();
    s.set_analytics_enabled(true).await.unwrap();

    let just_inside_day_30 = now_ms() - 30 * DAY_MS + 60 * 60 * 1000;

    let msg_id = MessageId::generate();
    s.send_message(NewMessage::plain(channel.id, member.id, msg_id, "old"))
        .await
        .unwrap();
    sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
        .bind(just_inside_day_30)
        .bind(msg_id)
        .execute(&pool)
        .await
        .unwrap();

    s.maybe_record_metrics_sample(12_345).await.unwrap();
    sqlx::query("UPDATE space_metrics_samples SET sampled_at = ?")
        .bind(just_inside_day_30)
        .execute(&pool)
        .await
        .unwrap();

    let stats = s.analytics_stats().await.unwrap();
    let hours_sum: i64 = stats.active_hours.iter().sum();
    assert_eq!(hours_sum, 1);
    assert_eq!(stats.memory_samples.len(), 1);
    assert_eq!(stats.memory_samples[0].rss_bytes, 12_345);
}

/// A sample older than the retention window is pruned on the next write,
/// which is the only sweep this series has: no background job, see
/// `store/analytics.rs`'s own doc comment.
#[tokio::test]
async fn a_stale_sample_is_pruned_on_the_next_write() {
    let (s, pool, _guard) = store("slimm-analytics-prune").await;
    s.maybe_record_metrics_sample(1_000).await.unwrap();

    let far_past = -(slimm_server::store::ANALYTICS_WINDOW_DAYS + 1) * 24 * 60 * 60 * 1000;
    sqlx::query("UPDATE space_metrics_samples SET sampled_at = ?")
        .bind(far_past)
        .execute(&pool)
        .await
        .unwrap();

    s.maybe_record_metrics_sample(2_000).await.unwrap();

    // Off the table directly: `analytics_stats`'s own windowed read would pass this even unpruned.
    let row_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM space_metrics_samples")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(row_count, 1);

    let stats = s.analytics_stats().await.unwrap();
    assert_eq!(stats.memory_samples.len(), 1);
    assert_eq!(stats.memory_samples[0].rss_bytes, 2_000);
}
