// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A waveform too narrow for one bar per value merges values, so its bars
/// keep their gaps instead of running into each other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/voice_waveform.dart';

const _wave = Key('wave');

Future<RenderObject> _paintAt(WidgetTester tester, double width) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: width,
          child: VoiceWaveform(
            key: _wave,
            values: List.generate(64, (i) => (i % 8) / 8),
            playedColor: const Color(0xFF000000),
            restColor: const Color(0xFF808080),
          ),
        ),
      ),
    ),
  );
  return tester.renderObject(
    find.descendant(
      of: find.byKey(_wave),
      matching: find.byWidgetPredicate((w) => w is CustomPaint),
    ),
  );
}

void main() {
  testWidgets('a narrow row draws fewer bars, 3 px apart', (tester) async {
    expect(await _paintAt(tester, 90), paintsExactlyCountTimes(#drawRRect, 30));
  });

  testWidgets('a row with room draws one bar per value', (tester) async {
    expect(
      await _paintAt(tester, 320),
      paintsExactlyCountTimes(#drawRRect, 64),
    );
  });
}
