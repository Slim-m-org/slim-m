// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Animated media stops ticking while nobody can see it: the window is
/// unfocused, or a sheet or dialog covers the page. Flutter keeps a page under
/// a non-opaque route mounted and animating, and the shell's pages sit in a
/// nested navigator that never learns a root sheet opened.
library;

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
  }
}
