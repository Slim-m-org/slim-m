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
    life.dispose();
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

  group('a frame asked for and never drawn', () {
    AppLifecycleNotifier watch() {
      return AppLifecycleNotifier(
        mobile: false,
        windowEvents: events.stream,
        frameStallCheck: const Duration(seconds: 1),
      );
    }

    testWidgets('reads as hidden until a frame is drawn again', (tester) async {
      await tester.pumpWidget(const SizedBox());
      _embedderSays(AppLifecycleState.inactive);
      final watched = watch();
      await tester.pump();
      tester.binding.scheduleFrame();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(watched.state, AppLifecycleState.inactive);

      await tester.binding.delayed(const Duration(seconds: 1));
      expect(watched.state, AppLifecycleState.hidden);

      await tester.pump();
      await tester.binding.delayed(Duration.zero);
      expect(watched.state, AppLifecycleState.inactive);
      watched.dispose();
    });

    testWidgets('an idle window with nothing to draw stays on screen', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.binding.delayed(const Duration(seconds: 10));
      expect(watched.state, AppLifecycleState.resumed);
      watched.dispose();
    });

    testWidgets('frames that keep arriving never count as a stall', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final watched = watch();
      for (var i = 0; i < 6; i++) {
        tester.binding.scheduleFrame();
        await tester.pump(const Duration(milliseconds: 900));
      }
      expect(watched.state, AppLifecycleState.resumed);
      watched.dispose();
    });
  });
}
