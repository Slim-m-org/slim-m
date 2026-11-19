// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A route's transition makes its curves once and lets them go with the
/// route: a route rebuilds its transition every frame it animates, and a
/// curve made there stayed listening to the route's animation.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/page_transitions.dart';
import 'package:slimm_design_system/design_system.dart';

class _Pages extends StatelessWidget {
  const _Pages(this.pages);

  final List<Page<void>> Function(BuildContext context) pages;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Builder(
      builder: (context) =>
          Navigator(pages: pages(context), onDidRemovePage: (_) {}),
    ),
  );
}

void main() {
  late List<CurvedAnimation> curves;

  void onEvent(ObjectEvent event) {
    final object = event.object;
    if (event is ObjectCreated && object is CurvedAnimation) curves.add(object);
  }

  setUp(() {
    curves = [];
    FlutterMemoryAllocations.instance.addListener(onEvent);
  });
  tearDown(() => FlutterMemoryAllocations.instance.removeListener(onEvent));

  Future<void> expectCurvesMadeOnce(
    WidgetTester tester,
    Page<void> Function(BuildContext context, String name) page,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Pages((context) => [page(context, 'one')]));
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(
      _Pages((context) => [page(context, 'one'), page(context, 'two')]),
    );
    await tester.pump();
    final afterFirstFrame = curves.length;
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      curves.length,
      afterFirstFrame,
      reason: 'a frame of the transition makes no new curve',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect([
      for (final curve in curves)
        if (!curve.isDisposed) curve,
    ], isEmpty);
  }

  testWidgets('a page that fades through', (tester) async {
    await expectCurvesMadeOnce(
      tester,
      (context, name) =>
          fadeThroughPage(context, Text(name), key: ValueKey(name)),
    );
  });

  testWidgets('a modal page', (tester) async {
    await expectCurvesMadeOnce(
      tester,
      (context, name) => name == 'one'
          ? MaterialPage<void>(key: ValueKey(name), child: Text(name))
          : modalPage(context, Text(name)),
    );
  });
}
