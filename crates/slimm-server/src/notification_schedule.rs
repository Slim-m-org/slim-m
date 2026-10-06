// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The per-weekday notification schedule (decision
//! `docs/decisions/0033-notification-schedule.md`): when an account wants to
//! be notified at all, evaluated in that account's own IANA time zone rather
//! than the fixed UTC-minutes window `notifications::QuietHours` used, so a
//! window drawn as "22:00-08:00" reads the same local hours on both sides of
//! a daylight-saving transition instead of drifting by an hour.
//!
//! This module is pure logic - no `Store`, no I/O - so the DST case and the
//! allow-list combinations in `push::recipients` can be tested without a
//! database. `store/notification_schedule.rs` is the persistence half.

use jiff::civil::Weekday;
use jiff::tz::TimeZone;
use jiff::{Timestamp, Zoned};

use crate::notifications::{MINUTES_PER_DAY, NotificationPreference};

/// Days in a week, and the length of [`Schedule::days`].
pub const WEEKDAYS: usize = 7;

/// One weekday's on-hours window: the account is notified normally during
/// this span, the same "everything outside is off hours" shape the owner's
/// own request described. Absent from [`Schedule::days`] entirely, a weekday
/// has no on-hours window at all - the whole day is off hours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DayWindow {
    pub start_minute: u16,
    pub end_minute: u16,
}

impl DayWindow {
    /// Builds a window from wire values, the same bounds
    /// [`crate::notifications::QuietHours::parse`] enforces: either minute
    /// outside `0..MINUTES_PER_DAY`, or the two equal, is refused.
    pub const fn parse(start_minute: i64, end_minute: i64) -> Option<Self> {
        let in_range = start_minute >= 0
            && start_minute < MINUTES_PER_DAY as i64
            && end_minute >= 0
            && end_minute < MINUTES_PER_DAY as i64;
        if !in_range || start_minute == end_minute {
            return None;
        }
        Some(Self {
            start_minute: start_minute as u16,
            end_minute: end_minute as u16,
        })
    }

    /// Whether this window, read as starting on its own weekday, covers
    /// `minute` of that same day - a window ending before midnight as a plain
    /// range, or, if it
    /// crosses midnight, everything from `start_minute` to the end of the
    /// day. The early-morning tail of a crossing window is
    /// [`DayWindow::tail_into_next_day`]'s job, not this one's, since that
    /// tail belongs to the *next* calendar day.
    fn covers_from_start(&self, minute: u16) -> bool {
        if self.start_minute < self.end_minute {
            (self.start_minute..self.end_minute).contains(&minute)
        } else {
            minute >= self.start_minute
        }
    }

    /// Whether this window, which started on the *previous* weekday, still
    /// covers `minute` on the day after: only possible when it crosses
    /// midnight, and only for minutes before `end_minute`.
    fn tail_into_next_day(&self, minute: u16) -> bool {
        self.start_minute > self.end_minute && minute < self.end_minute
    }
}

/// What breaks through during an off-hours window - the owner's own core
/// ask. Each variant is a floor: an allow-list (`channel_allowed`/
/// `author_allowed` in [`degrade_for_off_hours`]) can only ever raise a
/// message back up, never lower it further.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OffHoursMode {
    /// Mentions and DMs still notify - today's quiet-hours behaviour, and
    /// the default so nobody's push changes on upgrade.
    #[default]
    MentionsAndDms,
    /// Nothing notifies at all, including a mention or a DM, unless an
    /// allow-list says otherwise.
    Nothing,
}

impl OffHoursMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            OffHoursMode::MentionsAndDms => "mentions",
            OffHoursMode::Nothing => "nothing",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "mentions" => OffHoursMode::MentionsAndDms,
            "nothing" => OffHoursMode::Nothing,
            _ => return None,
        })
    }
}

/// One account's notification schedule: a per-weekday on-hours window, an
/// off-hours policy, and an optional snooze deadline. The two allow-lists
/// (people and channels) are looked up separately, per message, since they
/// can be large and are almost never checked - see
/// `push::recipients::narrow_for_notification_preference`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Schedule {
    /// An IANA time zone name (`"America/New_York"`), validated at write
    /// time with [`TimeZone::get`]. Evaluation fails open - see
    /// [`Schedule::evaluate`] - if the stored name is ever unresolvable, so
    /// a tzdb downgrade or a corrupt row can never turn into a dropped
    /// notification.
    pub timezone: String,
    /// Indexed Monday = 0 .. Sunday = 6, [`Weekday::to_monday_zero_offset`]'s
    /// own numbering, so the wire, the database and jiff all agree without a
    /// translation table.
    pub days: [Option<DayWindow>; WEEKDAYS],
    pub off_hours_mode: OffHoursMode,
    /// An epoch-millisecond deadline. While in the future, the schedule
    /// reads as off hours in [`OffHoursMode::Nothing`] regardless of the
    /// configured window or mode - the strongest policy for its duration -
    /// but still subject to both allow-lists, the same as any other
    /// off-hours window.
    pub snooze_until: Option<i64>,
}

/// The result of evaluating a [`Schedule`] against one instant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OffHoursState {
    OnHours,
    Off(OffHoursMode),
}

impl Schedule {
    /// Whether `now_ms` (epoch milliseconds, UTC) falls inside this
    /// account's off hours, and if so, which policy applies.
    ///
    /// Converts into [`Schedule::timezone`] before comparing against any
    /// window, which is the entire fix over the old UTC-minutes quiet
    /// hours: the same local wall-clock window holds across a
    /// daylight-saving transition because jiff recomputes the UTC offset
    /// for every instant, rather than a fixed offset baked in once.
    ///
    /// A window crossing midnight (Friday 22:00 into Saturday 02:00) is
    /// stored once, under the weekday it starts on; evaluating "now" checks
    /// both today's own window (has it started today and not yet ended) and
    /// yesterday's (did it start yesterday and cross into this morning).
    pub fn evaluate(&self, now_ms: i64) -> OffHoursState {
        if let Some(until) = self.snooze_until
            && now_ms < until
        {
            return OffHoursState::Off(OffHoursMode::Nothing);
        }
        let Some(zoned) = self.zoned_now(now_ms) else {
            // Fails open: no enforcement is the least surprising answer here.
            return OffHoursState::OnHours;
        };
        let weekday = monday_zero_index(zoned.weekday());
        let minute = zoned.hour() as u16 * 60 + zoned.minute() as u16;
        let yesterday = (weekday + WEEKDAYS - 1) % WEEKDAYS;
        let on_hours = self.days[weekday].is_some_and(|w| w.covers_from_start(minute))
            || self.days[yesterday].is_some_and(|w| w.tail_into_next_day(minute));
        if on_hours {
            OffHoursState::OnHours
        } else {
            OffHoursState::Off(self.off_hours_mode)
        }
    }

    fn zoned_now(&self, now_ms: i64) -> Option<Zoned> {
        let tz = TimeZone::get(&self.timezone).ok()?;
        let ts = Timestamp::from_millisecond(now_ms).ok()?;
        Some(ts.to_zoned(tz))
    }
}

fn monday_zero_index(weekday: Weekday) -> usize {
    weekday.to_monday_zero_offset() as usize
}

/// The core allow/deny decision for one recipient during off hours: given
/// their effective preference (already resolved from a channel override or
/// the account default), what should actually gate this message.
///
/// `channel_allowed` is this recipient's off-hours channel allow-list
/// containing the message's own channel - the strongest override, since it
/// bypasses off-hours narrowing entirely and lets the channel notify exactly
/// as it would in hours. `author_allowed` is their people allow-list
/// containing the message's author, a narrower override: it only ever floors
/// a `nothing`-mode drop back up to [`NotificationPreference::Mentions`],
/// matching the owner's own words ("an allow-list of members whose DMs and
/// mentions still notify") rather than letting an allow-listed person's
/// ordinary chatter through too.
pub fn degrade_for_off_hours(
    preference: NotificationPreference,
    state: OffHoursState,
    channel_allowed: bool,
    author_allowed: bool,
) -> NotificationPreference {
    if channel_allowed {
        return preference;
    }
    match state {
        OffHoursState::OnHours => preference,
        OffHoursState::Off(OffHoursMode::MentionsAndDms) => {
            if preference == NotificationPreference::Everything {
                NotificationPreference::Mentions
            } else {
                preference
            }
        }
        OffHoursState::Off(OffHoursMode::Nothing) => {
            if preference == NotificationPreference::Nothing {
                // An explicit mute outranks the schedule's own allow-list.
                NotificationPreference::Nothing
            } else if author_allowed {
                NotificationPreference::Mentions
            } else {
                NotificationPreference::Nothing
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workday_schedule(timezone: &str) -> Schedule {
        let window = DayWindow::parse(9 * 60, 17 * 60).unwrap();
        Schedule {
            timezone: timezone.to_owned(),
            days: [Some(window); WEEKDAYS],
            off_hours_mode: OffHoursMode::MentionsAndDms,
            snooze_until: None,
        }
    }

    fn ms_at(rfc3339: &str) -> i64 {
        let ts: Timestamp = rfc3339.parse().unwrap();
        ts.as_millisecond()
    }

    /// The owner's own motivating case: a schedule drawn in local time must
    /// read the same local hours on both sides of a DST transition, not
    /// shift by the offset change. 09:30 America/New_York is on-hours both
    /// the Friday before the US 2024-03-10 spring-forward (EST, UTC-5) and
    /// the Friday after (EDT, UTC-4) - two different UTC offsets, the same
    /// local answer.
    #[test]
    fn a_local_window_holds_across_a_dst_transition() {
        let schedule = workday_schedule("America/New_York");
        let before = ms_at("2024-03-08T14:30:00Z"); // 09:30 EST
        let after = ms_at("2024-03-15T13:30:00Z"); // 09:30 EDT
        assert_eq!(schedule.evaluate(before), OffHoursState::OnHours);
        assert_eq!(schedule.evaluate(after), OffHoursState::OnHours);
    }

    /// The same two instants, one minute before the local window opens,
    /// read as off hours on both sides of the same transition - proving the
    /// boundary itself moved with the clock, not just the middle of the
    /// window.
    #[test]
    fn the_boundary_also_holds_across_a_dst_transition() {
        let schedule = workday_schedule("America/New_York");
        let before = ms_at("2024-03-08T13:59:00Z"); // 08:59 EST
        let after = ms_at("2024-03-15T12:59:00Z"); // 08:59 EDT
        assert_eq!(
            schedule.evaluate(before),
            OffHoursState::Off(OffHoursMode::MentionsAndDms)
        );
        assert_eq!(
            schedule.evaluate(after),
            OffHoursState::Off(OffHoursMode::MentionsAndDms)
        );
    }

    #[test]
    fn a_weekday_absent_from_the_schedule_is_off_hours_all_day() {
        let mut schedule = workday_schedule("UTC");
        schedule.days[monday_zero_index(Weekday::Sunday)] = None;
        // A Sunday at noon UTC, with no Sunday window at all.
        let noon_sunday = ms_at("2024-03-10T12:00:00Z");
        assert_eq!(
            schedule.evaluate(noon_sunday),
            OffHoursState::Off(OffHoursMode::MentionsAndDms)
        );
    }

    /// Friday 22:00 into Saturday 02:00, the crossing-midnight shape the
    /// card names directly: 01:00 Saturday is on-hours because Friday's own
    /// window has not ended yet, even though Saturday has no window of its
    /// own that would otherwise cover it.
    #[test]
    fn a_window_crossing_midnight_covers_the_next_weekdays_early_morning() {
        let mut schedule = workday_schedule("UTC");
        let friday = monday_zero_index(Weekday::Friday);
        let saturday = monday_zero_index(Weekday::Saturday);
        schedule.days[friday] = DayWindow::parse(22 * 60, 2 * 60);
        schedule.days[saturday] = None;

        let one_am_saturday = ms_at("2024-03-09T01:00:00Z"); // 2024-03-08 is a Friday
        let three_am_saturday = ms_at("2024-03-09T03:00:00Z");
        assert_eq!(schedule.evaluate(one_am_saturday), OffHoursState::OnHours);
        assert_eq!(
            schedule.evaluate(three_am_saturday),
            OffHoursState::Off(OffHoursMode::MentionsAndDms)
        );
    }

    #[test]
    fn snooze_forces_nothing_mode_regardless_of_the_window() {
        let mut schedule = workday_schedule("America/New_York");
        schedule.snooze_until = Some(ms_at("2024-03-08T20:00:00Z"));
        let during_on_hours = ms_at("2024-03-08T14:30:00Z"); // 09:30 EST, would be on-hours
        assert_eq!(
            schedule.evaluate(during_on_hours),
            OffHoursState::Off(OffHoursMode::Nothing)
        );
    }

    #[test]
    fn snooze_expires_and_the_ordinary_schedule_resumes() {
        let mut schedule = workday_schedule("America/New_York");
        schedule.snooze_until = Some(ms_at("2024-03-08T14:00:00Z"));
        let after_expiry = ms_at("2024-03-08T14:30:00Z"); // 09:30 EST, on-hours
        assert_eq!(schedule.evaluate(after_expiry), OffHoursState::OnHours);
    }

    #[test]
    fn an_unresolvable_timezone_fails_open_to_on_hours() {
        let schedule = workday_schedule("Not/A_Real_Zone");
        assert_eq!(
            schedule.evaluate(ms_at("2024-03-08T14:30:00Z")),
            OffHoursState::OnHours
        );
    }

    #[test]
    fn mentions_mode_only_demotes_everything_never_raises_mentions_or_nothing() {
        let off = OffHoursState::Off(OffHoursMode::MentionsAndDms);
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Everything, off, false, false),
            NotificationPreference::Mentions
        );
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Mentions, off, false, false),
            NotificationPreference::Mentions
        );
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Nothing, off, false, false),
            NotificationPreference::Nothing
        );
    }

    #[test]
    fn nothing_mode_silences_everything_unless_allow_listed() {
        let off = OffHoursState::Off(OffHoursMode::Nothing);
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Everything, off, false, false),
            NotificationPreference::Nothing
        );
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Mentions, off, false, false),
            NotificationPreference::Nothing
        );
    }

    #[test]
    fn an_allow_listed_author_floors_nothing_mode_at_mentions_not_everything() {
        let off = OffHoursState::Off(OffHoursMode::Nothing);
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Everything, off, false, true),
            NotificationPreference::Mentions
        );
    }

    #[test]
    fn an_allow_listed_author_never_overrides_an_explicit_mute() {
        let off = OffHoursState::Off(OffHoursMode::Nothing);
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Nothing, off, false, true),
            NotificationPreference::Nothing
        );
    }

    #[test]
    fn an_allow_listed_channel_bypasses_off_hours_entirely() {
        let off = OffHoursState::Off(OffHoursMode::Nothing);
        assert_eq!(
            degrade_for_off_hours(NotificationPreference::Everything, off, true, false),
            NotificationPreference::Everything
        );
    }

    #[test]
    fn on_hours_never_changes_the_preference() {
        for preference in [
            NotificationPreference::Everything,
            NotificationPreference::Mentions,
            NotificationPreference::Nothing,
        ] {
            assert_eq!(
                degrade_for_off_hours(preference, OffHoursState::OnHours, false, false),
                preference
            );
        }
    }

    #[test]
    fn every_off_hours_mode_wire_spelling_round_trips() {
        for mode in [OffHoursMode::MentionsAndDms, OffHoursMode::Nothing] {
            assert_eq!(OffHoursMode::parse(mode.as_str()), Some(mode));
        }
    }

    #[test]
    fn an_unrecognized_off_hours_mode_parses_to_none() {
        assert_eq!(OffHoursMode::parse("everything"), None);
        assert_eq!(OffHoursMode::parse(""), None);
    }

    #[test]
    fn a_day_window_refuses_an_out_of_range_or_equal_pair() {
        assert_eq!(DayWindow::parse(-1, 100), None);
        assert_eq!(DayWindow::parse(100, 1440), None);
        assert_eq!(DayWindow::parse(500, 500), None);
        assert!(DayWindow::parse(0, 1439).is_some());
    }
}
