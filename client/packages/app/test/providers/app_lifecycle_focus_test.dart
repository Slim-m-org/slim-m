// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The window's own focus and minimise events keep the lifecycle honest when
/// the embedder leaves it stale, as it can after a locked screen or a launch
/// behind another window.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

/// Moves Flutter's own state one step at a time, as the embedder does.
void _embedderSays(AppLifecycleState target) {
  const order = [
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
  ];
  final binding = WidgetsBinding.instance;
  var at = order.indexOf(binding.lifecycleState ?? AppLifecycleState.resumed);
  if (binding.lifecycleState == null) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
  while (at != order.indexOf(target)) {
    at += at < order.indexOf(target) ? 1 : -1;
    binding.handleAppLifecycleStateChanged(order[at]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<DesktopWindowEventKind> events;
  late AppLifecycleNotifier life;
  late bool inTray;

  /// What the port does: the flag is up before the event goes out.
  void hideToTray() {
    inTray = true;
    events.add(DesktopWindowEventKind.hide);
  }

  void showFromTray() {
    inTray = false;
    events.add(DesktopWindowEventKind.show);
  }

  setUp(() {
    inTray = false;
    events = StreamController<DesktopWindowEventKind>.broadcast(sync: true);
    life = AppLifecycleNotifier(
      mobile: false,
      windowEvents: events.stream,
      inTray: () => inTray,
    );
  });

  tearDown(() async {
    if (life.mounted) life.dispose();
    await events.close();
    _embedderSays(AppLifecycleState.resumed);
  });

  test('focus lifts a stale hidden state', () {
    life.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(life.state, AppLifecycleState.hidden);

    events.add(DesktopWindowEventKind.focus);
    expect(life.state, AppLifecycleState.resumed);
  });

  test('losing focus reads as inactive, not hidden', () {
    events.add(DesktopWindowEventKind.focus);
    events.add(DesktopWindowEventKind.blur);
    expect(life.state, AppLifecycleState.inactive);
  });

  test('a window restored without focus is on screen again', () {
    life.didChangeAppLifecycleState(AppLifecycleState.resumed);
    events.add(DesktopWindowEventKind.minimize);
    life.didChangeAppLifecycleState(AppLifecycleState.inactive);
    life.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(life.state, AppLifecycleState.hidden);

    // Windows sends no restore event for a maximised window, only the embedder's state.
    life.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(life.state, AppLifecycleState.inactive);
  });

  test('the focus lost on the way to minimised does not undo it', () {
    life.didChangeAppLifecycleState(AppLifecycleState.resumed);
    events.add(DesktopWindowEventKind.minimize);
    life.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(life.state, AppLifecycleState.hidden);
  });

  test('a maximise while minimised defers to the embedder again', () {
    life.didChangeAppLifecycleState(AppLifecycleState.inactive);
    events.add(DesktopWindowEventKind.minimize);
    expect(life.state, AppLifecycleState.hidden);

    events.add(DesktopWindowEventKind.maximize);
    expect(life.state, AppLifecycleState.inactive);
  });

  test('a blur after minimising keeps the window hidden', () {
    events.add(DesktopWindowEventKind.minimize);
    events.add(DesktopWindowEventKind.blur);
    expect(life.state, AppLifecycleState.hidden);

    events.add(DesktopWindowEventKind.focus);
    expect(life.state, AppLifecycleState.resumed);
  });

  group('a window the app put in the tray', () {
    test('stays hidden when the tray menu focuses it', () {
      _embedderSays(AppLifecycleState.hidden);
      hideToTray();
      expect(life.state, AppLifecycleState.hidden);

      // Windows focuses the hidden window to open the tray menu, then blurs it.
      events.add(DesktopWindowEventKind.focus);
      expect(life.state, AppLifecycleState.hidden);
      expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.hidden);
      events.add(DesktopWindowEventKind.blur);
      expect(life.state, AppLifecycleState.hidden);
    });

    test('stays hidden through a maximise event', () {
      hideToTray();
      events.add(DesktopWindowEventKind.maximize);
      expect(life.state, AppLifecycleState.hidden);
    });

    test('is hidden even if the embedder never says so', () {
      hideToTray();
      expect(life.state, AppLifecycleState.hidden);
    });

    test('is known to a notifier made after the hide', () {
      _embedderSays(AppLifecycleState.hidden);
      hideToTray();
      final late = AppLifecycleNotifier(
        mobile: false,
        windowEvents: events.stream,
        inTray: () => inTray,
      );
      addTearDown(late.dispose);

      events.add(DesktopWindowEventKind.focus);
      expect(late.state, AppLifecycleState.hidden);
      expect(life.state, AppLifecycleState.hidden);
    });

    test('comes back on show, and focus counts again', () {
      _embedderSays(AppLifecycleState.hidden);
      hideToTray();

      showFromTray();
      expect(life.state, AppLifecycleState.inactive);
      events.add(DesktopWindowEventKind.focus);
      expect(life.state, AppLifecycleState.resumed);
    });

    test('comes back when the embedder reports it on screen', () {
      _embedderSays(AppLifecycleState.hidden);
      hideToTray();

      inTray = false;
      _embedderSays(AppLifecycleState.inactive);
      expect(life.state, AppLifecycleState.inactive);
    });
  });

  group('a stale embedder is corrected, not only the provider', () {
    testWidgets('focus turns frames back on', (tester) async {
      await tester.pumpWidget(const SizedBox());
      _embedderSays(AppLifecycleState.hidden);
      expect(SchedulerBinding.instance.framesEnabled, isFalse);

      events.add(DesktopWindowEventKind.focus);
      expect(life.state, AppLifecycleState.resumed);
      expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);
      expect(SchedulerBinding.instance.framesEnabled, isTrue);
    });

    testWidgets('a window shown without focus draws again', (tester) async {
      await tester.pumpWidget(const SizedBox());
      _embedderSays(AppLifecycleState.hidden);

      events.add(DesktopWindowEventKind.show);
      expect(life.state, AppLifecycleState.inactive);
      expect(SchedulerBinding.instance.framesEnabled, isTrue);
    });

    testWidgets('a maximised window un-minimised without focus draws again', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      events.add(DesktopWindowEventKind.maximize);
      expect(life.state, AppLifecycleState.inactive);
      expect(SchedulerBinding.instance.framesEnabled, isTrue);
    });

    test('the binding is walked one step at a time', () {
      final seen = <AppLifecycleState>[];
      final listener = AppLifecycleListener(onStateChange: seen.add);
      addTearDown(listener.dispose);
      _embedderSays(AppLifecycleState.hidden);
      seen.clear();

      events.add(DesktopWindowEventKind.focus);
      expect(seen, [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    });

    test('a blur the embedder missed changes the provider only', () {
      events.add(DesktopWindowEventKind.blur);
      expect(life.state, AppLifecycleState.inactive);
      // A pop-out window taking focus must not park the whole app's focus.
      expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);

      events.add(DesktopWindowEventKind.minimize);
      events.add(DesktopWindowEventKind.show);
      expect(life.state, AppLifecycleState.inactive, reason: 'still blurred');
      events.add(DesktopWindowEventKind.focus);
      expect(life.state, AppLifecycleState.resumed);
    });
  });

  group('a window the compositor stopped painting', () {
    late bool suspended;

    AppLifecycleNotifier watch() {
      final watched = AppLifecycleNotifier(
        mobile: false,
        windowEvents: events.stream,
        inTray: () => inTray,
        suspended: () => suspended,
      );
      addTearDown(watched.dispose);
      return watched;
    }

    void suspend() {
      suspended = true;
      events.add(DesktopWindowEventKind.suspend);
    }

    void unsuspend() {
      suspended = false;
      events.add(DesktopWindowEventKind.unsuspend);
    }

    setUp(() => suspended = false);

    test('reads as hidden, and as on screen again when painting resumes', () {
      final watched = watch();
      // A Wayland minimise: focus goes, then the compositor suspends the window.
      _embedderSays(AppLifecycleState.inactive);
      suspend();
      expect(watched.state, AppLifecycleState.hidden);

      unsuspend();
      expect(watched.state, AppLifecycleState.inactive);
      _embedderSays(AppLifecycleState.resumed);
      expect(watched.state, AppLifecycleState.resumed);
    });

    test(
      'is hidden even while it keeps the focus, as behind a lock screen',
      () {
        final watched = watch();
        suspend();
        expect(watched.state, AppLifecycleState.hidden);
        events.add(DesktopWindowEventKind.focus);
        expect(watched.state, AppLifecycleState.hidden);

        unsuspend();
        expect(watched.state, AppLifecycleState.resumed);
      },
    );

    testWidgets(
      'leaves frames on, so a wrong report cannot freeze the window',
      (tester) async {
        await tester.pumpWidget(const SizedBox());
        final watched = watch();
        suspend();
        expect(watched.state, AppLifecycleState.hidden);
        expect(
          WidgetsBinding.instance.lifecycleState,
          AppLifecycleState.resumed,
        );
        expect(SchedulerBinding.instance.framesEnabled, isTrue);
      },
    );

    test('is known to a notifier made after it happened', () {
      suspend();
      expect(watch().state, AppLifecycleState.hidden);
    });

    test('a blur while suspended is not remembered past it', () {
      final watched = watch();
      suspend();
      events.add(DesktopWindowEventKind.blur);
      unsuspend();
      expect(watched.state, AppLifecycleState.resumed);
    });
  });

  group('a focus event on a window that may still be minimised', () {
    late bool minimized;
    late bool queryable;
    late int asked;

    AppLifecycleNotifier watch() {
      final watched = AppLifecycleNotifier(
        mobile: false,
        windowEvents: events.stream,
        inTray: () => inTray,
        stillMinimized: () async {
          asked++;
          if (!queryable) throw const WindowNotQueryable();
          return minimized;
        },
      );
      addTearDown(watched.dispose);
      return watched;
    }

    setUp(() {
      // The shared notifier has nothing to ask, and would take the focus at its word.
      life.dispose();
      minimized = true;
      queryable = true;
      asked = 0;
    });

    testWidgets('does not end the minimise or wake Flutter', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      // Windows activates a window it leaves minimised, and window_manager reports focus.
      events.add(DesktopWindowEventKind.focus);
      await tester.idle();

      expect(asked, 1);
      expect(watched.state, AppLifecycleState.hidden);
      expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.hidden);
      expect(SchedulerBinding.instance.framesEnabled, isFalse);
    });

    testWidgets('is checked by a notifier that never saw the minimise', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      _embedderSays(AppLifecycleState.hidden);
      final late = watch();

      events.add(DesktopWindowEventKind.focus);
      await tester.idle();

      expect(late.state, AppLifecycleState.hidden);
      expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.hidden);
    });

    testWidgets('ends it once the window says it is restored', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      minimized = false;
      events.add(DesktopWindowEventKind.focus);
      await tester.idle();

      expect(watched.state, AppLifecycleState.resumed);
      expect(SchedulerBinding.instance.framesEnabled, isTrue);
    });

    testWidgets('restored but blurred while asking is on screen, unfocused', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      minimized = false;
      events.add(DesktopWindowEventKind.focus);
      events.add(DesktopWindowEventKind.blur);
      await tester.idle();

      expect(watched.state, AppLifecycleState.inactive);
      expect(SchedulerBinding.instance.framesEnabled, isTrue);
    });

    testWidgets('a focus just ahead of the restore event counts once it lands', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      // Asked while the restore is still under way, so the window says minimised.
      events.add(DesktopWindowEventKind.focus);
      await tester.idle();
      expect(watched.state, AppLifecycleState.hidden);

      events.add(DesktopWindowEventKind.show);
      expect(watched.state, AppLifecycleState.resumed);
    });

    testWidgets('a focus lost again before the restore does not count', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      _embedderSays(AppLifecycleState.hidden);

      events.add(DesktopWindowEventKind.focus);
      events.add(DesktopWindowEventKind.blur);
      await tester.idle();
      events.add(DesktopWindowEventKind.show);

      expect(watched.state, AppLifecycleState.inactive);
    });

    test('a window that cannot answer stays as it was', () async {
      final watched = watch();
      events.add(DesktopWindowEventKind.minimize);
      queryable = false;

      events.add(DesktopWindowEventKind.focus);
      await Future<void>.delayed(Duration.zero);

      expect(watched.state, AppLifecycleState.hidden);
    });

    test('a window on screen is not asked at all', () {
      final watched = watch();
      events.add(DesktopWindowEventKind.blur);
      events.add(DesktopWindowEventKind.focus);
      expect(asked, 0);
      expect(watched.state, AppLifecycleState.resumed);
    });
  });
}
