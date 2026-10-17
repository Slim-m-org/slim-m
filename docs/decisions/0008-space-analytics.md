# 0008 - Space usage analytics

Date: 2026-08-05.
Status: built.
Raised by the owner in the `backlog` channel: "I think I'd also like some sort of data visualizations perhaps of a spaces usage like total messages, members active hours, these are server side analytics kind of things so where we have the space settings button we also have a toggle for recording analytics just to have some cool stats on hand."

This is also the metrics half of `docs/ROADMAP.md` Phase 7, never started until now.
The owner's framing wins where the two differ: he asked for Space usage stats a person finds interesting, not only operational telemetry, and the toggle he asked for is a real product decision, not decoration.

## Derived, not recorded

Total messages, messages per day, and active hours all come from `messages.created_at`, which already exists for the product's core purpose (a message needs a timestamp to render in order).
Computing an aggregate over it on read is not new data collection - it is a coarser view of data every member with `VIEW_CHANNEL` can already see message by message.
`Store::analytics_stats` (`crates/slimm-server/src/store/analytics.rs`) derives all of this fresh on every read: no new table, no write path, nothing that could drift from the messages themselves, and it is retroactive by construction - turning the toggle on for the first time answers with the Space's whole history, not only what happens afterward.

The one thing genuinely recorded is this server process's own resident memory, in a new `space_metrics_samples` table (migration `0033_space_analytics.sql`).
There is no way to derive a process's past memory use from anything else already stored; it has to be sampled at the time.

## The toggle gates the whole feature, not only the recording

The owner asked for "a toggle for recording analytics."
Read literally, that would only need to gate the one recorded series (memory), since the derived counts need no recording to exist.
That reading was rejected: this product's stated posture is a self-hosted friend group with no automated content scanning, and an aggregate view of message activity that computed itself whether or not anyone asked for it would sit uneasily next to that, even though the underlying messages were never secret from their own channel's members.

So the toggle (`space_settings.analytics_enabled`, default `0`) gates `GET /space/analytics` entirely.
Off, the route answers `{"enabled": false}` with no `stats` key computed at all - not filtered out after the fact, never derived in the first place.
On, it answers the full derived-plus-recorded payload, retroactively for the derived half.
"Off" means the feature does not run, not only that a background job is paused.

## Default: off

Argued for explicitly, not left to whichever branch was easiest.
Nothing about a self-hosted friend-group messaging app should compute and display usage statistics about its members without somebody asking for it first, even in aggregate.
Every existing deployment that upgrades keeps this off, the same shape `join_policy` already established for `space_settings`.

## Aggregate versus surveillance: where the line is drawn

The owner's own example, "members active hours," is the one place this could have gone wrong.
The line drawn: **a count is a stat, a name attached to a count is monitoring.**

- `active_hours` is a 24-bucket histogram, summed across every author, over the trailing 30 days.
  There is no `GROUP BY author_id` anywhere in its query, and there is no route, parameter, or planned extension that narrows it to one member.
- `messages_by_day` is the same shape: a Space-wide daily count, never per author.
- Nothing about who sent which message is anywhere in the response.
  `the_analytics_response_never_names_a_member` (`crates/slimm-server/tests/space_analytics.rs`) asserts this structurally, against the serialized JSON rather than the Rust struct: it registers two accounts, seeds a message, and checks that neither account's id, username, nor display name appears anywhere in the response text at any depth.
  The same technique `no_op_carries_an_actor_on_any_kind` already uses for `message_ops`, because a field added anywhere in a future change to this response should fail this test rather than pass by accident.

A per-member "when were they online" timeline was never built, and nothing here derives it accidentally: `presence.rs` already tracks per-user status for its own reasons, and this feature does not read it or expose it.
If a future request asks for per-member analytics specifically, that is a different feature with a different, sharper privacy question, not an extension of this one.

## What switching it off does to existing data

Two different answers for two different kinds of data, because they are not the same kind of thing.

**Derived stats have nothing to keep or discard.** They were never stored; turning the toggle off just stops the route from computing them. Turning it back on re-derives the same history from the messages that are still there.

**Recorded memory samples are kept, not deleted, when the toggle goes off.** `Store::set_analytics_enabled` only writes the flag; nothing purges `space_metrics_samples`. Reasoning: those rows carry no per-member content, only this process's own memory readings, so there is nothing sensitive to protect by deleting them. Discarding history on every accidental untoggle would be a worse trap than keeping it, and turning the feature back on then shows a continuous series rather than starting over. There is no separate "clear analytics data" action in this slice, named here rather than left silently absent, the same way the canvas's first slice named erase as deliberately not built.

## Who can see it

`MANAGE_SERVER`, the same deployment-wide bit `/space/settings` and the Emoji screen already use, gating both the toggle and the read.
Not a new bit: this is exactly the kind of "change what this deployment is" decision that bit already means, and a second bit for one more screen would only be a second thing to keep in sync with the first.

## Measured against the Phase 1 idle budget

The committed baseline (`perf/baselines/0.8.0.json`) is 7,296 kB idle / 25,760 kB peak, taken on a much smaller binary eight releases ago; today's binary with this change absent already idles higher than that from unrelated growth, so the fair comparison is this change against itself, not against a four-month-old number.

Built the release binary twice from the same commit, once with this feature's commits stashed out and once with them restored, and measured a freshly booted, never-called process both times (glibc, `/proc/<pid>/status`, two readings two seconds apart to confirm a settled value, the same method `perf/measure-idle-rss.sh` uses):

- Without the feature: 9,096 kB idle RSS.
- With the feature, toggle off, zero requests served: 8,988 kB idle RSS.

The difference is noise, not a cost: with the toggle off, nothing this feature added ever runs, so there is nothing for idle RSS to measure.

With the toggle turned on and `GET /space/analytics` read 55 times, RSS reached 29,704 kB and then held flat over 50 further reads (no leak).
That reads alarming next to 9 MB until it is isolated from ordinary request-serving warm-up: a second, unrelated control server that never touched analytics at all, only `GET /channels` and `GET /me` 55 times each, reached 30,564 kB under the same method - higher than the analytics server, not lower.
The jump is the one-time cost of a process actually serving real authenticated JSON traffic at all (tokio worker stacks, sqlx's prepared-statement cache, serde codegen paths, allocator arena growth), which every route pays once, not something specific to this feature.
Isolated from that noise, this feature's own marginal RSS cost is not distinguishable from zero with the methodology available here.

Disk: `space_metrics_samples` rows measured at roughly 32 bytes each after `VACUUM` (a synthetic 8,640-row fill, `VACUUM`, byte delta against the same database before the fill).
8,640 is the theoretical ceiling for the 30-day retention window if every single sample opportunity landed exactly 5 minutes apart with no gaps - about 272 KB.
That ceiling is not the realistic case: a sample is only taken when an administrator opens the analytics screen, not on a timer, so real usage is expected to be a handful of rows a day at most.

## What the roadmap's original spec asked for that this does not build

Phase 7 named raw retention for 24h, 5-minute averages for 30 days, and daily averages for 1 year, plus a `/metrics` Prometheus endpoint.
Neither is built here, and both are named rather than silently dropped.

A three-tier downsampling scheme needs a sweep job that rolls raw samples into averages and prunes the raw tier on a schedule - real complexity, and complexity this feature does not need yet, because sampling is already lazy and bounded by usage rather than by a timer.
If continuous, high-resolution operational monitoring is wanted later, that is closer to the roadmap's original Prometheus-endpoint idea than to this screen, and the two are not the same feature: this one is the Space's own admin-facing usage picture, at hobbyist scale, not an operator's monitoring stack.
A `/metrics` endpoint was not built for the same reason: nothing in this deployment's target audience (a small self-hosted friend group) is running Prometheus against it, and the owner's ask was specifically for something visible in the app, not a scrape target.
Both remain open if a future request asks for them by name.

## What was built

- Server: migration `0033_space_analytics.sql` (`space_settings.analytics_enabled`, `space_metrics_samples`); `store/analytics.rs`; `http/analytics.rs` (`GET`/`PATCH /space/analytics`, both `MANAGE_SERVER`-gated); `process_metrics.rs` (Linux `/proc/self/status` RSS reader, `None` elsewhere rather than erroring the request it rides on).
- Client: `screens/admin/analytics_screen.dart` and `analytics_charts.dart` (the toggle, the off notice, four stat tiles, three charts); `widgets/analytics_bar_chart.dart`, a hand-rolled `CustomPainter` bar chart reused for all three series rather than a charting dependency (see `docs/dependencies.md`); a Space settings row gated the same as Emoji.
- Tests: `crates/slimm-server/tests/space_analytics.rs` (the toggle default and round trip, the disabled-answers-nothing property, real derived counts, DM exclusion from the channel count, the no-member-named privacy structural test, the MANAGE_SERVER gate, the memory-sample gap and prune logic) and `client/packages/app/test/features/settings/analytics_screen_test.dart` (the off notice, the toggle reaching the API, the headline numbers rendering as visible text and the chart's Semantics label carrying the same series for a screen reader).
