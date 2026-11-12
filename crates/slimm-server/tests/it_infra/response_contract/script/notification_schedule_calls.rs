// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The notification schedule's own routes, a sibling module rather than
//! folded into `script.rs` (already near the line budget) - the same split
//! `content_dm_calls.rs` uses for its own two routes.

use serde_json::json;

use crate::response_contract::world::Contract;

/// One minute from now, in epoch milliseconds - `setNotificationSnooze`'s
/// own contract call needs a real future deadline, not a fixed constant
/// that ages into the past as this suite keeps running.
fn snooze_deadline_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    now + 60_000
}

/// The notification schedule end to end: set a weekly window, allow-list a
/// person and a channel, read the schedule back with both lists populated,
/// snooze, cancel the snooze, then clear the whole schedule.
pub(super) async fn notification_schedule_calls(
    c: &mut Contract,
    root: &str,
    channel: &str,
    bob_id: &str,
) {
    c.json(
        "setNotificationSchedule",
        "PUT",
        "/notifications/schedule",
        root,
        json!({
            "timezone": "America/New_York",
            "off_hours_mode": "nothing",
            "days": [{ "weekday": 0, "start_minute": 9 * 60, "end_minute": 17 * 60 }],
        }),
    )
    .await;
    c.bare(
        "addNotificationScheduleAllowedUser",
        "PUT",
        &format!("/notifications/schedule/allowed-users/{bob_id}"),
        root,
    )
    .await;
    c.bare(
        "addNotificationScheduleAllowedChannel",
        "PUT",
        &format!("/notifications/schedule/allowed-channels/{channel}"),
        root,
    )
    .await;
    c.get("getNotificationSchedule", "/notifications/schedule", root)
        .await;
    c.json(
        "setNotificationSnooze",
        "PUT",
        "/notifications/schedule/snooze",
        root,
        json!({ "until_ms": snooze_deadline_ms() }),
    )
    .await;
    c.bare(
        "clearNotificationSnooze",
        "DELETE",
        "/notifications/schedule/snooze",
        root,
    )
    .await;
    c.bare(
        "removeNotificationScheduleAllowedUser",
        "DELETE",
        &format!("/notifications/schedule/allowed-users/{bob_id}"),
        root,
    )
    .await;
    c.bare(
        "removeNotificationScheduleAllowedChannel",
        "DELETE",
        &format!("/notifications/schedule/allowed-channels/{channel}"),
        root,
    )
    .await;
    c.bare(
        "clearNotificationSchedule",
        "DELETE",
        "/notifications/schedule",
        root,
    )
    .await;
}
