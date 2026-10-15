// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AppCodeBlock]'s fold: a long block collapses to a preview with a toggle,
/// a short one never does, and the header (with its action) stays through
/// both, so a folded block can still be run without expanding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

List<AppCodeLine> _lines(int n) =>
    [for (var i = 0; i < n; i++) AppCodeLine.plain('line $i')];

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('a block over the threshold collapses with a toggle', (
    tester,
  ) async {
    await _pump(
      tester,
      AppCodeBlock(lines: _lines(20), collapseAfterLines: 12),
    );

    expect(find.text('Show 8 more lines'), findsOneWidget);
  });

  testWidgets('tapping the toggle expands and collapses again', (tester) async {
    await _pump(
      tester,
      AppCodeBlock(lines: _lines(20), collapseAfterLines: 12),
    );

    await tester.tap(find.text('Show 8 more lines'));
    await tester.pump();
    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.text('Show 8 more lines'), findsOneWidget);
  });

  testWidgets('a short block never collapses', (tester) async {
    await _pump(
      tester,
      AppCodeBlock(lines: _lines(5), collapseAfterLines: 12),
    );
    expect(find.textContaining('Show'), findsNothing);
  });

  testWidgets('the action stays available while collapsed', (tester) async {
    await _pump(
      tester,
      AppCodeBlock(
        lines: _lines(20),
        collapseAfterLines: 12,
        action: const Icon(Icons.play_arrow, key: Key('run')),
      ),
    );
    expect(find.byKey(const Key('run')), findsOneWidget);
    expect(find.text('Show 8 more lines'), findsOneWidget);
  });

  testWidgets('a null threshold never collapses, however long the block', (
    tester,
  ) async {
    // Tall surface: an uncollapsed 50-line block is not vertically scrollable on its own (it lives in a scrolling transcript in real use).
    tester.view.physicalSize = const Size(600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, AppCodeBlock(lines: _lines(50)));
    expect(find.textContaining('Show'), findsNothing);
  });

  testWidgets('the toggle meets the touch floor at touch density (issue 2035)',
      (
    tester,
  ) async {
    await _pump(
      tester,
      AppTouchTargets(
        enabled: true,
        child: AppCodeBlock(lines: _lines(20), collapseAfterLines: 12),
      ),
    );
    final toggle = find.ancestor(
      of: find.text('Show 8 more lines'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(44));
  });
}
