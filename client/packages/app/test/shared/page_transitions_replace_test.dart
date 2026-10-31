// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel switch replaces one page with another under the shell. The old
/// page leaves through the Navigator's removal, so its exit must clear before
/// the new page becomes legible: at no frame may both contents be visible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/page_transitions.dart';
import 'package:slimm_design_system/design_system.dart';

const Key _a = Key('channel-a');
const Key _b = Key('channel-b');
const Key _c = Key('channel-c');
const double _legible = 0.05;

GoRouter _router() => GoRouter(
  initialLocation: '/a',
  routes: [
    ShellRoute(
      builder: (context, state, child) => Scaffold(body: child),
      routes: [
        for (final id in ['a', 'b', 'c'])
          GoRoute(
            path: '/$id',
            pageBuilder: (context, state) => fadeThroughPage(
              context,
              Text('channel $id', key: Key('channel-$id')),
              key: ValueKey('channel-$id'),
            ),
          ),
      ],
    ),
  ],
);

double _opacity(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  if (finder.evaluate().isEmpty) return 0;
  var opacity = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: finder, matching: find.byType(FadeTransition)),
  )) {
    opacity *= fade.opacity.value;
  }
  return opacity;
}

Future<void> _pumpApp(WidgetTester tester, GoRouter router, bool reduce) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(disableAnimations: reduce),
      child: MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('switching channels never shows both contents at once', (
    tester,
  ) async {
    final router = _router();
    await _pumpApp(tester, router, false);
    expect(_opacity(tester, _a), 1);

    router.go('/b');
    await tester.pump();
    var worst = 0.0;
    for (
      var t = Duration.zero;
      t <= AppMotion.base * 1.2;
      t += const Duration(milliseconds: 10)
    ) {
      final a = _opacity(tester, _a);
      final b = _opacity(tester, _b);
      final both = a < b ? a : b;
      if (both > worst) worst = both;
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(worst, lessThan(_legible), reason: 'both panes legible at once');
    expect(_opacity(tester, _b), 1);
    expect(find.byKey(_a), findsNothing);
  });

  testWidgets('a switch interrupted mid-flight still never overlaps', (
    tester,
  ) async {
    final router = _router();
    await _pumpApp(tester, router, false);
    router.go('/b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    router.go('/c');
    await tester.pump();
    var worst = 0.0;
    for (var i = 0; i < 40; i++) {
      final o = [_a, _b, _c].map((k) => _opacity(tester, k)).toList()..sort();
      if (o[1] > worst) worst = o[1];
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(worst, lessThan(_legible));
  });

  testWidgets('reduce motion swaps instantly', (tester) async {
    final router = _router();
    await _pumpApp(tester, router, true);
    router.go('/b');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_a), findsNothing);
    expect(_opacity(tester, _b), 1);
  });

  testWidgets('a compact switch slides an opaque page over the old one', (
    tester,
  ) async {
    final router = _router();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();

    router.go('/b');
    await tester.pump();
    await tester.pump(AppMotion.base ~/ 2);

    final backing = tester.widget<ColoredBox>(
      find
          .ancestor(of: find.byKey(_b), matching: find.byType(ColoredBox))
          .first,
    );
    expect(backing.color.a, 1, reason: 'a transparent page shows the old one');
  });
}
