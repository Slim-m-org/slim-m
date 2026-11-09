// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Animated media stops ticking while nobody can see it: the window is
/// unfocused, or a sheet or dialog covers the page. Flutter keeps a page under
/// a non-opaque route mounted and animating, and the shell's pages sit in a
/// nested navigator that never learns a root sheet opened.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/overlay_cover.dart';
import 'package:slimm_app/src/widgets/animation_gate.dart';
import 'package:slimm_app/src/widgets/viewport_freeze.dart';
import 'package:slimm_design_system/design_system.dart';

bool? _gated;
bool? _ungated;

class _Probe extends StatelessWidget {
  const _Probe(this.sink);

  final void Function(bool) sink;

  @override
  Widget build(BuildContext context) {
    sink(TickerMode.valuesOf(context).enabled);
    return const SizedBox(width: 40, height: 40);
  }
}

/// The page lives in a nested navigator, as the shell's pages do.
Future<BuildContext> _pump(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  late BuildContext pageContext;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        navigatorObservers: [
          OverlayCoverObserver(
            (n) => container.read(overlayCoverProvider.notifier).state = n,
          ),
        ],
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) {
              pageContext = context;
              return Column(
                children: [
                  AnimationGate(child: _Probe((v) => _gated = v)),
                  ViewportFreeze(child: _Probe((v) => _ungated = v)),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return pageContext;
}

/// A route's entrance is a timed transition, so a plain pump past it, not a settle that would hide a ticker still running.
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    _gated = null;
    _ungated = null;
  });

  testWidgets('an unfocused window stops the animation, focus restarts it', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await _pump(tester);
    expect(_gated, isTrue);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(_gated, isFalse);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_gated, isTrue);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('a sheet over the page stops the animation at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final page = await _pump(tester);
      expect(_gated, isTrue);

      final closed = showAppSheet<void>(
        page,
        builder: (_) => const SizedBox(height: 80, child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsOneWidget);
      expect(_gated, isFalse, reason: 'covered: no ticker may run');
      expect(
        _ungated,
        isTrue,
        reason: 'without the gate Flutter keeps it animating under the sheet',
      );

      Navigator.of(page, rootNavigator: true).pop();
      await closed;
      await tester.pumpAndSettle();
      expect(_gated, isTrue, reason: 'uncovered: it plays again');
    });

    testWidgets('an image inside the topmost sheet plays at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final page = await _pump(tester);
      bool? inSheet;

      unawaited(
        showAppSheet<void>(
          page,
          builder: (_) => AnimationGate(child: _Probe((v) => inSheet = v)),
        ),
      );
      await _settleRoute(tester);

      expect(inSheet, isTrue, reason: 'nothing is above the sheet it is in');
      expect(_gated, isFalse, reason: 'the page beneath it is still covered');
    });

    testWidgets('a sheet under a second sheet pauses until the second closes '
        'at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final page = await _pump(tester);
      bool? first;
      bool? second;

      unawaited(
        showAppSheet<void>(
          page,
          builder: (_) => AnimationGate(child: _Probe((v) => first = v)),
        ),
      );
      await _settleRoute(tester);
      expect(first, isTrue);

      unawaited(
        showAppSheet<void>(
          page,
          builder: (_) => AnimationGate(child: _Probe((v) => second = v)),
        ),
      );
      await _settleRoute(tester);
      expect(second, isTrue, reason: 'the second sheet is the topmost');
      expect(first, isFalse, reason: 'the first sheet is now covered');

      Navigator.of(page, rootNavigator: true).pop();
      await _settleRoute(tester);
      expect(first, isTrue, reason: 'uncovered again: it plays');
    });

    testWidgets('a page stays paused beneath an opaque route and a sheet, and '
        'plays once both are gone at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final page = await _pump(tester);
      final root = Navigator.of(page, rootNavigator: true);

      unawaited(
        root.push(
          MaterialPageRoute<void>(builder: (_) => const Text('full screen')),
        ),
      );
      await _settleRoute(tester);
      unawaited(
        showAppSheet<void>(page, builder: (_) => const Text('sheet on top')),
      );
      await _settleRoute(tester);
      root.pop();
      await _settleRoute(tester);
      expect(_gated, isFalse, reason: 'the full screen route still covers it');

      root.pop();
      await _settleRoute(tester);
      expect(_gated, isTrue, reason: 'nothing covers it any more');
    });
  }
}
