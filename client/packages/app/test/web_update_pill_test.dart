// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web-update pill stays hidden until version.json names a build other
/// than the running one, reloads only on its own button, and a dismissal holds
/// until a newer build than the dismissed one appears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/web_update/web_update_pill.dart';
import 'package:slimm_app/src/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/web_update/web_update_watch.dart';
import 'package:slimm_design_system/design_system.dart';

class _Harness {
  _Harness({String running = 'aaa', bool supported = true}) {
    container = ProviderContainer(
      overrides: [
        runningWebBuildProvider.overrideWithValue(running),
        webUpdateSupportedProvider.overrideWithValue(supported),
        webBuildFetcherProvider.overrideWithValue(() async => live),
      ],
    );
  }

  late final ProviderContainer container;
  String? live = 'aaa';
  int reloads = 0;

  Future<void> pump(WidgetTester tester, {Size size = const Size(1200, 800)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: WebUpdatePill(onReload: () => reloads++),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> tick(WidgetTester tester) async {
    await tester.pump(webUpdateWatchInterval);
    await tester.pump();
  }
}

void main() {
  // Disposing the container runs the watcher's onDispose, which cancels its poll timer.
  Future<void> unmount(WidgetTester tester, _Harness h) async {
    await tester.pumpWidget(const SizedBox.shrink());
    h.container.dispose();
  }

  testWidgets('hidden while version.json matches the running build', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump();
    expect(find.text('Reload'), findsNothing);
    await unmount(tester, h);
  });

  testWidgets('on a phone it sits below the app bar, not over its actions', (
    tester,
  ) async {
    final h = _Harness()..live = 'bbb';
    await h.pump(tester, size: const Size(390, 800));
    await h.tick(tester);
    expect(
      tester.getTopLeft(find.text('Reload')).dy,
      greaterThanOrEqualTo(CompactChannelAppBar.height),
    );
    await unmount(tester, h);
  });

  testWidgets('appears when a poll reports a different build', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.pump();
    expect(find.text('Reload'), findsNothing);

    h.live = 'bbb';
    await h.tick(tester);

    expect(find.text('New version available'), findsOneWidget);
    expect(find.text('Reload'), findsOneWidget);
    expect(h.reloads, 0);
    await unmount(tester, h);
  });

  testWidgets('shows on the first poll when a newer build is already live', (
    tester,
  ) async {
    final h = _Harness()..live = 'bbb';
    await h.pump(tester);
    await tester.pump();
    expect(find.text('Reload'), findsOneWidget);
    await unmount(tester, h);
  });

  testWidgets('a failed poll never shows the pill', (tester) async {
    final h = _Harness()..live = null;
    await h.pump(tester);
    await tester.pump();
    await h.tick(tester);
    expect(find.text('Reload'), findsNothing);
    await unmount(tester, h);
  });

  testWidgets('only the Reload button reloads', (tester) async {
    final h = _Harness()..live = 'bbb';
    await h.pump(tester);
    await tester.pump();

    await tester.tap(find.text('New version available'));
    expect(h.reloads, 0);

    await tester.tap(find.text('Reload'));
    expect(h.reloads, 1);
    await unmount(tester, h);
  });

  testWidgets('dismiss hides it until a newer build than the dismissed one', (
    tester,
  ) async {
    final h = _Harness()..live = 'bbb';
    await h.pump(tester);
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Dismiss'));
    await tester.pump();
    expect(find.text('Reload'), findsNothing);

    await h.tick(tester);
    expect(find.text('Reload'), findsNothing);

    h.live = 'ccc';
    await h.tick(tester);
    expect(find.text('Reload'), findsOneWidget);
    await unmount(tester, h);
  });

  testWidgets('a build without an id never shows it', (tester) async {
    final h = _Harness(running: '', supported: false)..live = 'bbb';
    await h.pump(tester);
    await tester.pump();
    await h.tick(tester);
    expect(find.text('Reload'), findsNothing);
    await unmount(tester, h);
  });

  testWidgets('top-centre on a wide window and on a phone', (tester) async {
    final h = _Harness()..live = 'bbb';
    await h.pump(tester);
    await tester.pump();
    final wide = tester.getRect(find.text('New version available'));
    expect(wide.center.dx, closeTo(600, 60));
    expect(wide.center.dy, lessThan(100));

    tester.view.physicalSize = const Size(390, 800);
    await tester.pump();
    final phone = tester.getRect(find.text('New version available'));
    expect(phone.center.dy, lessThan(100));
    expect(phone.right, lessThan(390));
    await unmount(tester, h);
  });
}
