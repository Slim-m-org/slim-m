// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-day message counts in `Store::analytics_stats`, value by value.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::MessageId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{ANALYTICS_WINDOW_DAYS, NewMessage, Store};

mod support;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_millis() as i64
}

fn utc_date(ms: i64) -> String {
    jiff::Timestamp::from_millisecond(ms)
        .unwrap()
        .to_zoned(jiff::tz::TimeZone::UTC)
        .strftime("%Y-%m-%d")
        .to_string()
}

#[tokio::test]
async fn every_displayed_day_counts_its_whole_utc_day_zeros_included() {
    let (path, _guard) = support::TestDbGuard::new("slimm-analytics-by-day");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let s = Store::new(pool.clone());
    let view_send = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    s.create_role("everyone", view_send, true).await.unwrap();
    let member = s.create_user("nia", "Nia").await.unwrap();
    let channel = s.create_channel("general", "text").await.unwrap();
    s.set_analytics_enabled(true).await.unwrap();

    let today_start = now_ms().div_euclid(DAY_MS) * DAY_MS;
    let days_back = ANALYTICS_WINDOW_DAYS - 1;
    // (days before today, ms into that UTC day, how many)
    let seeded = [
        (days_back, 1, 1),
        (days_back, 12 * 60 * 60 * 1000, 1),
        (10, 5_000, 2),
        (0, 1, 1),
    ];
    for (back, offset, count) in seeded {
        for _ in 0..count {
            let id = MessageId::generate();
            s.send_message(NewMessage::plain(channel.id, member.id, id, "m"))
                .await
                .unwrap();
            sqlx::query("UPDATE messages SET created_at = ? WHERE id = ?")
                .bind(today_start - back * DAY_MS + offset)
                .bind(id)
                .execute(&pool)
                .await
                .unwrap();
        }
    }

    let stats = s.analytics_stats().await.unwrap();
    let expected: Vec<(String, i64)> = (0..ANALYTICS_WINDOW_DAYS)
        .rev()
        .map(|back| {
            let count = match back {
                29 => 2,
                10 => 2,
                0 => 1,
                _ => 0,
            };
            (utc_date(today_start - back * DAY_MS), count)
        })
        .collect();
    let actual: Vec<(String, i64)> = stats
        .messages_by_day
        .into_iter()
        .map(|d| (d.date, d.count))
        .collect();
    assert_eq!(actual, expected);
}
