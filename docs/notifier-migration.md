# StateNotifier to Notifier migration plan

## Why

The app has 69 files with a class that extends `StateNotifier` (72 classes) and only 8 `Notifier` or `AsyncNotifier` classes.
flutter_riverpod is on 2.6.x (`client/packages/app/pubspec.yaml`).
Riverpod 3 moves `StateNotifier` to a legacy import, so the upgrade gets more expensive with every new controller.

## What is enforced now

`client/packages/app/test/state_notifier_gate_test.dart` fails on any file that gains a `StateNotifier` subclass.
The allowlist is `client/packages/app/test/state_notifier_allow.txt`: one line per file with its remaining count.
It may only shrink, and a migrated file must leave it in the same commit.
The count is tracked per release by the line total of that file, so the number to quote in release notes is `grep -c . state_notifier_allow.txt` minus the header.

## How to migrate one controller

1. Replace `extends StateNotifier<S>` with `extends Notifier<S>` (or `AsyncNotifier<S>` when `build` must await).
2. Move constructor arguments read from other providers into `build()`, using `ref.watch` for values that should rebuild the controller and `ref.read` for ones that should not.
3. Replace `super(initial)` with `S build() => initial`.
4. Replace the `StateNotifierProvider` with `NotifierProvider` (add `.autoDispose` or `.family` as before).
5. Move `dispose()` work to `ref.onDispose` inside `build()`.
6. Tests that built the controller directly now read it through a `ProviderContainer`; tests that subclassed it override `build`.

## Order

1. Leaf preferences with no collaborators: `*_preference.dart`, `*_settings.dart`, `rail_width_preference`, `recent_emoji`, `reply_mention_preference`.
2. Selection and UI state: `member_selection`, `message_selection`, `toasts`, `canvas_grid_snap`.
3. Per-feature controllers that only read a few providers: blocks, reports, pins, typing, channel search.
4. Controllers with timers or streams: presence, ring, hotkeys, mic preview.
5. Last: `sync_controller`, `voice_controller`, `push_controller`, `app_lock_controller`, which carry the most tests and test-local subclasses.

## Done when

Fewer than 15 remain, at which point evaluate riverpod 3 once and migrate the rest as part of that upgrade.
