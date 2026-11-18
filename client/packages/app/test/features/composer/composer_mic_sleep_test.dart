// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mic that takes Send's place after a send stays asleep while it is
/// being clicked, so repeated clicks on Send never start a recording.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';

import 'composer_voice_swap_test.dart' show pumpBar;
import 'voice_recording_test.dart' show FakeActions, FakeCapture;

void main() {
  final record = find.byTooltip('Record a voice message');
  final bar = find.byKey(const Key('composer-voice-bar'));
  const half = Duration(milliseconds: 400);

  testWidgets('clicks on a sleeping mic keep it asleep', (tester) async {
    final capture = FakeCapture();
    await pumpBar(
      tester,
      canRecord: true,
      canSend: false,
      capture: capture,
      actions: FakeActions(),
    );
    await tester.pump(half);
    await tester.tap(record, warnIfMissed: false);
    await tester.pump(half);
    // Past the first wake-up, but a click came in meanwhile.
    await tester.tap(record, warnIfMissed: false);
    await tester.pump();
    expect(bar, findsNothing);
    expect(capture.started, isFalse);

    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(record);
    await tester.pump();
    expect(bar, findsOneWidget);
    expect(capture.started, isTrue);
  });
}
