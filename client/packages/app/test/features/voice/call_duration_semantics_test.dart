// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call clock ticks every second on screen but reads in whole minutes, so
/// a screen reader is not handed a changed node, and a new announcement, each
/// second.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('the spoken clock counts whole minutes', () {
    expect(spokenCallClock(const Duration(seconds: 42)), 'under a minute');
    expect(spokenCallClock(const Duration(minutes: 1, seconds: 5)), '1 minute');
    expect(
      spokenCallClock(const Duration(minutes: 12, seconds: 59)),
      '12 minutes',
    );
    expect(spokenCallClock(const Duration(hours: 1)), '1 hour');
    expect(
      spokenCallClock(const Duration(hours: 2, minutes: 3, seconds: 4)),
      '2 hours 3 minutes',
    );
  });

  testWidgets('the readout keeps one label while its seconds tick', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final since = DateTime.now().subtract(const Duration(minutes: 3));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Center(child: CallDuration(since: since)),
      ),
    );
    final finder = find.byWidgetPredicate((w) => w is CallDuration);

    final before = tester.getSemantics(finder).label;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(seconds: 2));
    final after = tester.getSemantics(finder).label;

    expect(before, '3 minutes');
    expect(after, before);
    handle.dispose();
  });
}
