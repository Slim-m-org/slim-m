// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [InputLevelMeter]: the line is where the threshold says, the level splits
/// into below and above it, and an automatic line is read-only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/input_level_meter.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, child: child)),
  ),
);

void main() {
  const above = ValueKey('input-level-above');
  const below = ValueKey('input-level-below');

  testWidgets('a level past the line draws accent beyond it', (tester) async {
    await tester.pumpWidget(
      _harness(
        InputLevelMeter(
          key: inputLevelMeterKey,
          thresholdDb: -40,
          levelDb: -20,
          status: InputLevelStatus.sending,
          onChanged: (_) {},
        ),
      ),
    );
    expect(tester.getSize(find.byKey(above)).width, closeTo(100, 0.5));
    expect(tester.getSize(find.byKey(below)).width, closeTo(200, 0.5));
    expect(find.text('Sending'), findsOneWidget);
  });

  testWidgets('a level under the line draws no accent', (tester) async {
    await tester.pumpWidget(
      _harness(
        InputLevelMeter(
          key: inputLevelMeterKey,
          thresholdDb: -40,
          levelDb: -60,
          status: InputLevelStatus.notSent,
          onChanged: (_) {},
        ),
      ),
    );
    expect(tester.getSize(find.byKey(above)).width, 0);
    expect(find.text('Below the line, not sent'), findsOneWidget);
  });

  testWidgets('tapping the bar moves the line to that level', (tester) async {
    double? moved;
    await tester.pumpWidget(
      _harness(
        InputLevelMeter(
          key: inputLevelMeterKey,
          thresholdDb: -40,
          status: InputLevelStatus.waiting,
          onChanged: (db) => moved = db,
        ),
      ),
    );
    final left = tester.getTopLeft(find.byKey(inputLevelMeterKey)).dx;
    final y = tester
        .getCenter(find.byKey(const ValueKey('input-threshold-line')))
        .dy;
    await tester.tapAt(Offset(left + 100, y));
    expect(moved, -60);
  });

  testWidgets('an automatic line cannot be dragged and says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const InputLevelMeter(
          key: inputLevelMeterKey,
          thresholdDb: -46,
          status: InputLevelStatus.waiting,
          auto: true,
          onChanged: null,
        ),
      ),
    );
    expect(
      find.text('Automatic: the line follows your room, now at -46 dB.'),
      findsOneWidget,
    );
    final line = tester.getCenter(
      find.byKey(const ValueKey('input-threshold-line')),
    );
    await tester.tapAt(Offset(line.dx + 80, line.dy));
    expect(tester.takeException(), isNull);
  });
}
