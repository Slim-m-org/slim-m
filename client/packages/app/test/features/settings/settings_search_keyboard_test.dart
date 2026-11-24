// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings search by keyboard: the arrow keys keep the chosen result in view
/// and the results say how many there are.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_search.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

final _entries = [
  for (var i = 0; i < 40; i++)
    SettingsEntry('appearance', 'Probe row ${i.toString().padLeft(2, '0')}'),
];

Future<void> _pump(WidgetTester tester, List<SettingsEntry> entries) async {
  tester.view.physicalSize = const Size(600, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SettingsSearchArea(
          entries: entries,
          paneLabels: const {'appearance': 'Appearance'},
          onOpen: (_) {},
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: const SizedBox(),
        ),
      ),
    ),
  );
  await tester.enterText(find.byKey(const Key('settings-search')), 'probe');
  await tester.pump();
}

void main() {
  testWidgets('arrow down keeps the selected result on screen', (tester) async {
    await _pump(tester, _entries);
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpFrames(tester, frames: 10);
    }
    final row = find.byKey(
      const ValueKey('settings-result-appearance-Probe row 30'),
    );
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(400));
  });

  testWidgets('the results announce their count and an empty search says so', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _entries);
    expect(
      tester.getSemantics(find.bySemanticsLabel('40 results')),
      matchesSemantics(label: '40 results', isLiveRegion: true),
    );

    await tester.enterText(find.byKey(const Key('settings-search')), 'zzzz');
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('No settings match')),
      matchesSemantics(label: 'No settings match', isLiveRegion: true),
    );
    handle.dispose();
  });
}
