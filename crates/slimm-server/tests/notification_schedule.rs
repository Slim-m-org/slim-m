// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The notification schedule (migration 0081), through the real
//! `message_recipients` pipeline - every mode and allow-list combination the
//! owner's own request named.
//!
//! Every window here is drawn around the real current UTC minute rather than
//! a fixed clock (the store has no injectable one), the same technique,
//! applied to every weekday at once, since which weekday "now" happens to be must not change
//! whether these tests pass.

use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::ids::{DeviceId, UserId};
use slimm_server::notification_schedule::{OffHoursMode, WEEKDAYS};
use slimm_server::notifications::MINUTES_PER_DAY;
use slimm_server::store::{DaySetting, PushRegistration, Store};

mod support;
use support::wake_recipients;

const KEY: [u8; 32] = [7u8; 32];

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn wrap(minute: i64) -> u16 {
    minute.rem_euclid(i64::from(MINUTES_PER_DAY)) as u16
}

fn minute_of_day_utc(ms: i64) -> u16 {
    ((ms / 60_000) % i64::from(MINUTES_PER_DAY)) as u16
}

/// A window guaranteed to contain the current UTC minute, on every weekday.
fn on_hours_every_day() -> Vec<DaySetting> {
    let now = i64::from(minute_of_day_utc(now_ms()));
    let window = DayWindowFor::parse(wrap(now - 5) as i64, wrap(now + 5) as i64).unwrap();
    (0..WEEKDAYS as u8)
        .map(|weekday| DaySetting { weekday, window })
        .collect()
}

/// A window guaranteed to exclude the current UTC minute, on every weekday -
/// "now" is off hours under every one of these.
fn off_hours_every_day() -> Vec<DaySetting> {
    let now = i64::from(minute_of_day_utc(now_ms()));
    let window = DayWindowFor::parse(wrap(now + 15) as i64, wrap(now + 25) as i64).unwrap();
    (0..WEEKDAYS as u8)
        .map(|weekday| DaySetting { weekday, window })
        .collect()
}

/// An alias that avoids a name collision with `DaySetting`'s own field.
type DayWindowFor = slimm_server::notification_schedule::DayWindow;

async fn new_store(name: &str) -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(name);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

async fn account(store: &Store, username: &str) -> (UserId, DeviceId) {
    let account = store
        .create_account(username, username, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let session = store.open_session(account.id, "phone").await.unwrap();
    (account.id, session.device_id)
}

async fn register(store: &Store, user: UserId, device: DeviceId, token: &str) {
    store
        .register_push(
            user,
            device,
            PushRegistration {
                platform: "ios",
                push_token: token,
                voip_push_token: None,
                push_public_key: &KEY,
                include_content: Some(false),
                include_content_chosen: true,
            },
        )
        .await
        .unwrap();
}

async fn set_schedule(store: &Store, user: UserId, mode: OffHoursMode, days: Vec<DaySetting>) {
    store
        .set_notification_schedule(user, "UTC", mode, &days)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_fresh_account_has_no_notification_schedule() {
    let (store, _guard) = new_store("slimm-schedule-default").await;
    let (bob, _) = account(&store, "bob").await;
    assert!(store.notification_schedule(bob).await.unwrap().is_none());
}

#[tokio::test]
async fn set_and_get_round_trips_the_full_schedule() {
    let (store, _guard) = new_store("slimm-schedule-roundtrip").await;
    let (bob, _) = account(&store, "bob").await;
    let days = vec![DaySetting {
        weekday: 0,
        window: DayWindowFor::parse(9 * 60, 17 * 60).unwrap(),
    }];
    set_schedule(&store, bob, OffHoursMode::Nothing, days).await;

    let detail = store.notification_schedule(bob).await.unwrap().unwrap();
    assert_eq!(detail.schedule.timezone, "UTC");
    assert_eq!(detail.schedule.off_hours_mode, OffHoursMode::Nothing);
    assert!(detail.schedule.days[0].is_some());
    assert!(detail.schedule.days[1..].iter().all(Option::is_none));
}

#[tokio::test]
async fn clearing_the_schedule_reverts_to_never_configured() {
    let (store, _guard) = new_store("slimm-schedule-clear").await;
    let (bob, _) = account(&store, "bob").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, on_hours_every_day()).await;
    assert!(store.notification_schedule(bob).await.unwrap().is_some());

    store.clear_notification_schedule(bob).await.unwrap();
    assert!(store.notification_schedule(bob).await.unwrap().is_none());
}

/// On hours, both modes behave identically to having no schedule at all.
#[tokio::test]
async fn on_hours_a_plain_message_still_wakes_an_everything_recipient() {
    for mode in [OffHoursMode::MentionsAndDms, OffHoursMode::Nothing] {
        let (store, _guard) = new_store("slimm-schedule-on-hours").await;
        let (alice, alice_device) = account(&store, "alice").await;
        let (bob, bob_device) = account(&store, "bob").await;
        let channel = store.list_channels().await.unwrap()[0].id;
        register(&store, alice, alice_device, "alice-token").await;
        register(&store, bob, bob_device, "bob-token").await;
        set_schedule(&store, bob, mode, on_hours_every_day()).await;

        let recipients = wake_recipients(&store, channel, alice, "just chatting")
            .await
            .unwrap();
        assert!(
            recipients.contains(&bob),
            "bob is on hours under {mode:?}, got {recipients:?}"
        );
    }
}

#[tokio::test]
async fn off_hours_mentions_mode_suppresses_a_plain_message_but_not_a_mention() {
    let (store, _guard) = new_store("slimm-schedule-off-mentions").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(
        &store,
        bob,
        OffHoursMode::MentionsAndDms,
        off_hours_every_day(),
    )
    .await;

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(!plain.contains(&bob), "off hours, plain: {plain:?}");

    let mentioned = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        mentioned.contains(&bob),
        "mentions-and-dms mode still lets a mention through: {mentioned:?}"
    );
}

#[tokio::test]
async fn off_hours_nothing_mode_suppresses_a_mention_too() {
    let (store, _guard) = new_store("slimm-schedule-off-nothing").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;

    let mentioned = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        !mentioned.contains(&bob),
        "nothing mode silences even a mention: {mentioned:?}"
    );
}

#[tokio::test]
async fn an_allow_listed_author_breaks_through_nothing_mode_for_a_mention() {
    let (store, _guard) = new_store("slimm-schedule-allow-author-mention").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;
    store
        .add_notification_schedule_allowed_user(bob, alice)
        .await
        .unwrap();

    let mentioned = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        mentioned.contains(&bob),
        "an allow-listed author's mention still lands: {mentioned:?}"
    );
}

/// The allow-list only ever floors nothing mode at mentions-shaped: an
/// allow-listed author's ordinary channel chatter, with no mention and no
/// DM, still does not wake the recipient.
#[tokio::test]
async fn an_allow_listed_author_does_not_unlock_ordinary_chatter() {
    let (store, _guard) = new_store("slimm-schedule-allow-author-plain").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;
    store
        .add_notification_schedule_allowed_user(bob, alice)
        .await
        .unwrap();

    let plain = wake_recipients(&store, channel, alice, "just chatting, no mention")
        .await
        .unwrap();
    assert!(
        !plain.contains(&bob),
        "an allow-listed author's plain chatter is still off hours: {plain:?}"
    );
}

#[tokio::test]
async fn an_allow_listed_channel_notifies_as_normal_in_nothing_mode() {
    let (store, _guard) = new_store("slimm-schedule-allow-channel").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;
    store
        .add_notification_schedule_allowed_channel(bob, channel)
        .await
        .unwrap();

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        plain.contains(&bob),
        "an allow-listed channel notifies as normal even in nothing mode: {plain:?}"
    );
}

/// The channel allow-list is scoped to the channel it names: a different
/// channel gets no benefit from it.
#[tokio::test]
async fn a_channel_allow_list_entry_does_not_help_a_different_channel() {
    let (store, _guard) = new_store("slimm-schedule-allow-channel-scoped").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channels = store.list_channels().await.unwrap();
    let allowed_channel = channels[0].id;
    let other_channel = store.create_channel("general-2", "text").await.unwrap().id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;
    store
        .add_notification_schedule_allowed_channel(bob, allowed_channel)
        .await
        .unwrap();

    let plain = wake_recipients(&store, other_channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        !plain.contains(&bob),
        "the allow-list is scoped to its own channel: {plain:?}"
    );
}

/// Quiet hours never touched an account that already chose `nothing`; this
/// schedule keeps the same rule.
#[tokio::test]
async fn nothing_preference_is_unaffected_by_the_schedule_either_way() {
    let (store, _guard) = new_store("slimm-schedule-preexisting-nothing").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    store
        .set_notification_preference(
            bob,
            slimm_server::notifications::NotificationPreference::Nothing,
        )
        .await
        .unwrap();
    set_schedule(&store, bob, OffHoursMode::Nothing, off_hours_every_day()).await;
    store
        .add_notification_schedule_allowed_user(bob, alice)
        .await
        .unwrap();

    let mentioned = wake_recipients(&store, channel, alice, "hey @bob look")
        .await
        .unwrap();
    assert!(
        !mentioned.contains(&bob),
        "an explicit nothing preference is never resurrected by an allow-list: {mentioned:?}"
    );
}

#[tokio::test]
async fn snooze_forces_nothing_mode_even_during_an_on_hours_window() {
    let (store, _guard) = new_store("slimm-schedule-snooze-active").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(
        &store,
        bob,
        OffHoursMode::MentionsAndDms,
        on_hours_every_day(),
    )
    .await;
    store
        .set_notification_snooze(bob, Some(now_ms() + 60_000))
        .await
        .unwrap();

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        !plain.contains(&bob),
        "an active snooze silences: {plain:?}"
    );
}

#[tokio::test]
async fn an_expired_snooze_stops_overriding_the_schedule() {
    let (store, _guard) = new_store("slimm-schedule-snooze-expired").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    set_schedule(
        &store,
        bob,
        OffHoursMode::MentionsAndDms,
        on_hours_every_day(),
    )
    .await;
    store
        .set_notification_snooze(bob, Some(now_ms() - 60_000))
        .await
        .unwrap();

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        plain.contains(&bob),
        "an expired snooze no longer applies, the ordinary on-hours schedule does: {plain:?}"
    );
}

/// `set_notification_snooze` on an account with no schedule at all creates
/// an always-on placeholder that changes nothing once the snooze itself
/// expires - see that method's own doc comment.
#[tokio::test]
async fn snoozing_with_no_schedule_configured_does_not_outlive_the_snooze() {
    let (store, _guard) = new_store("slimm-schedule-snooze-bootstrap").await;
    let (alice, alice_device) = account(&store, "alice").await;
    let (bob, bob_device) = account(&store, "bob").await;
    let channel = store.list_channels().await.unwrap()[0].id;
    register(&store, alice, alice_device, "alice-token").await;
    register(&store, bob, bob_device, "bob-token").await;
    assert!(store.notification_schedule(bob).await.unwrap().is_none());

    store
        .set_notification_snooze(bob, Some(now_ms() - 60_000))
        .await
        .unwrap();

    let plain = wake_recipients(&store, channel, alice, "just chatting")
        .await
        .unwrap();
    assert!(
        plain.contains(&bob),
        "the placeholder schedule is on hours all day once the snooze expires: {plain:?}"
    );
}
