// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The what's-new body says it scrolls: a rule above the pinned button while more waits below.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(
  WidgetTester tester,
  Size window,
  double scale, [
  List<WhatsNewEntry>? entries,
]) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      builder: (context, child) => MediaQuery(
        data: MediaQueryData.fromView(
          View.of(context),
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showWhatsNewSheet(context, entries ?? whatsNewEntries),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('overflowing notes show the rule until the end is reached', (
    tester,
  ) async {
    await _open(tester, const Size(390, 600), 2.0);
    expect(find.byKey(whatsNewScrollRuleKey), findsOneWidget);

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(whatsNewScrollRuleKey), findsNothing);
  });

  testWidgets('notes that fit show no rule', (tester) async {
    // Its own one-line entry: the newest real one grows release by release.
    const short = WhatsNewEntry(
      version: '0.0.1',
      headline: 'One change',
      points: [WhatsNewPoint('A single short line.')],
    );
    await _open(tester, const Size(1600, 1400), 1.0, [short]);
    expect(find.byKey(whatsNewScrollRuleKey), findsNothing);
  });
}
