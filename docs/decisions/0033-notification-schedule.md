# 0033 - The notification schedule: per-weekday hours, timezone-correct, with an off-hours policy

Status: accepted
Date: 2026-09-25

## The owner's request

> "sortve what slack has for quiet hours, I don't want notifications outside of my defined hours and outside of my defined hours I can configure it specifically, like for mentions only or certain people only or channels outside of normal hours"

## What quiet hours already got wrong

Quiet hours (migration 0056) shipped one daily window, stored as `start_minute`/`end_minute` since midnight UTC.
Two gaps kept it from being what the owner asked for.

First, the window drifts with daylight saving time.
The client converts a local time to UTC minutes once, at save time, and the server only ever compares against that fixed pair.
A window drawn as "22:00-08:00" is correct the day it is saved, and wrong by an hour on the far side of the next DST transition, because the stored minutes never move but the account's own clock does.
Somebody who travels, or simply lives through March or November, silently gets the wrong hours until they resave the window.

Second, one window applies to every day, and there was exactly one way to be woken inside it: a mention or a DM.
The owner's own words ask for both a schedule that varies by day and a choice of what gets through outside it - mentions only, certain people, or certain channels - which quiet hours had no room for at all.

## The model

A new table, `notification_schedules`, keyed by account, holding an IANA time zone name, an off-hours policy, and a snooze deadline.
A sibling table, `notification_schedule_days`, holds up to seven rows, one per weekday, each an on-hours window in that account's own local time.
A weekday absent from the table has no on-hours window at all - the whole day is off hours - which is how "weekdays 9-5, weekends off" is expressed: five rows, not seven.

Evaluating "is now off hours" converts the current instant into the account's own zone (via `jiff`, see below) before comparing against the window, rather than comparing UTC minutes directly.
The same local window then holds on both sides of a DST transition, because the conversion recomputes the correct UTC offset for the instant in question every time, instead of a client baking one offset in once.

A window can cross midnight into the next weekday (Friday 22:00 into Saturday 02:00 is the ordinary shape a night-shift schedule needs).
It is stored once, under the weekday it starts on.
Evaluating "is this weekday's morning still covered" checks two things: today's own row, for a window that starts and ends the same day, and yesterday's row, for a window that started yesterday and has not yet reached its end minute.
That is the same clock-face reasoning the old `QuietHours::contains` (since deleted) used for a single wrapping window, extended across a weekday boundary instead of collapsing back to it every midnight.

## The off-hours policy

Two modes, both familiar from quiet hours' own shape:

- **Mentions and DMs.** An `everything` preference is narrowed to `mentions` off hours, exactly quiet hours' old behaviour. This is the default, so an existing quiet-hours account's push does not change at all on upgrade.
- **Nothing.** Off hours silences everything, including a mention or a DM, unless an allow-list says otherwise. This is the stronger setting quiet hours never offered, and it is what "I don't want notifications outside of my defined hours" actually asks for.

Two allow-lists sit alongside the mode, and they are additive rather than a third and fourth mode, because the owner's own example - "mentions-only plus everything from #alerts" - describes a mode plus an exception, not a fifth policy:

- **People** (`notification_schedule_allowed_users`). A DM or mention from an allow-listed person still notifies off hours, floored at mentions-shaped even under `nothing` mode - "still notify me about this person," never "let this person say anything and wake me." This is also the member card's "notify me about this person off-hours" action, and it works before an account has ever turned the schedule on at all: the list is independent of whether a schedule row exists, so the action is never a no-op-that-looks-like-a-bug waiting for a schedule to catch up.
- **Channels** (`notification_schedule_allowed_channels`). An allow-listed channel bypasses off-hours narrowing entirely, notifying exactly as it would in hours - the channel menu's "notify me off-hours here" action, and the stronger of the two overrides, since a channel like `#alerts` is meant to behave as if off hours never applied to it at all.

Neither allow-list ever overrides an account's own explicit `nothing` preference (account-wide or per-channel).
An allow-list breaks through the *schedule's* silence; it is not licensed to un-mute a channel or a person the account already muted on purpose.

## Snooze

A `snooze_until` epoch-millisecond deadline on the same row.
While it is in the future, the schedule reads as off hours in `nothing` mode regardless of the configured window or mode - the strongest policy for its duration, Slack's "pause notifications" - still subject to both allow-lists, so a VIP is never silenced by a snooze either.
30m/1h/until-tomorrow are client concepts: the client computes the concrete deadline (only it knows the account's own local midnight for "until tomorrow") and the server only bounds how far out it may be.

Snoozing an account with no schedule configured at all creates an always-on placeholder (every weekday 00:00-23:59, mentions-and-DMs mode) purely to host the deadline, so that once the snooze itself expires, push behaves exactly as it did before the account ever touched this feature.
An account that goes on to configure a real weekly schedule overwrites this placeholder the ordinary way.

## The call-ring decision

A DM call ring is not narrowed by this schedule, in either mode.
`push::call_ring::deliver` already ignored quiet hours for the same reason: a direct call is at least as addressed-to-you as an ordinary DM message, and quiet hours never demoted a DM below `mentions`.
`nothing` mode is the one place this project could plausibly have chosen differently, since it is stronger than anything quiet hours could express - but the owner's own request describes wanting the *chatter* silenced, not wanting to become unreachable by an actual call, and Slack's own do-not-disturb makes the identical call-rings-through exception.
The one preference that still suppresses a ring is the account's own `nothing` notification preference: opting out of every notification, DMs included, also opts out of being rung.
This is stated in the client's schedule settings screen, next to the off-hours mode picker, so it is never a silent surprise.

## Migrating existing quiet-hours users

Migration 0081 seeds a `notification_schedules` row, with every weekday's window identical, for every account that had quiet hours set.
The timezone is `UTC`, not a guessed device zone: the stored quiet-hours minutes were always UTC clock minutes, so a schedule that also reads them as UTC reproduces the exact same absolute window every day, bit for bit, not an approximation.
Guessing a device zone from inside a SQL migration was rejected outright - there is no device to ask at migration time, and a wrong guess would be a real behaviour change dressed as a preserving one, exactly the outcome this migration exists to avoid.

The window itself is inverted: quiet hours named the window to go quiet in, and this table names the window to stay on in, so the migration writes `(end_minute, start_minute)` rather than `(start_minute, end_minute)`.
This is not a special case - the complement of a circular interval `[start, end)`, read the same clock-face way the old `QuietHours::contains` and `DayWindow` both did, is exactly `[end, start)` - so swapping the two fields is the whole transformation, verified in `notification_schedule_migration.rs` against a database seeded before 0081 ran.

The old `quiet_hours_start_minute`/`quiet_hours_end_minute` columns and the `/push/quiet-hours` routes are untouched.
An old client, or an API consumer that predates this feature, keeps working exactly as before.
What moved is enforcement: `push::recipients` now reads the new schedule, not those columns, so writing through the old routes alone no longer changes anything about a live account's push.

## Why `jiff`, not `chrono-tz`

Correct DST handling needs a real IANA time zone database, not a fixed UTC-offset table.
`chrono-tz` is the obvious incumbent, but the release image is `gcr.io/distroless/static-debian12`, which ships no `/usr/share/zoneinfo` at all - a runtime `TZDIR` lookup would simply fail on every self-hosted deployment using the published image.
`jiff` (the same author's line of work as `regex` and `ripgrep`, already a documented influence on this project's other dependency choices) offers a `tzdb-bundle-always` feature that compiles the entire IANA database into the binary, so time zone resolution needs nothing from the host at all, on any platform this server ships to.
`chrono-tz` has an equivalent embed-the-database story too, but adopting it would mean carrying both `chrono` and `jiff`-shaped code long term for no reason: this project has no `chrono` dependency today, so `jiff` is a clean net-new addition rather than a second datetime library growing alongside an existing one.

## What this record does not decide

- A UI for editing the underlying IANA time zone directly. The settings screen picks up the device's own zone; changing it to a different one is not exposed in v1.
- Whether the allow-lists ever grow a UI-visible "why" beyond the member card and channel menu entry points named above.
