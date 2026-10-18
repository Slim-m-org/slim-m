// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's level bar rises at once and falls steadily, because the native
/// gate reports each poll's loudest frame rather than a decaying peak.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/mic_level_ballistics.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

void main() {
  late FakeSession session;
  late ProviderContainer container;
  late DateTime now;
  final levels = <double>[];

  setUp(() {
    now = DateTime(2026);
    levels.clear();
    session = FakeSession(supportsInputGate: true);
    container = ProviderContainer(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
        micLevelClockProvider.overrideWithValue(() => now),
      ],
    );
    container.listen<double>(
      localMicLevelProvider,
      (_, next) => levels.add(next),
      fireImmediately: true,
    );
    container.listen(inputGateReadingProvider, (_, _) {});
    addTearDown(() async {
      container.dispose();
      await session.dispose();
    });
  });

  Future<void> poll(double db, {int afterMs = 50}) async {
    now = now.add(Duration(milliseconds: afterMs));
    session.inputGateController.add(InputGateReading(levelDb: db, voice: true));
    await Future<void>.delayed(Duration.zero);
  }

  test('a rise shows at once', () async {
    await poll(-80);
    await poll(-20);
    expect(levels.last, closeTo(0.75, 0.03));
  });

  test('one loud poll then quiet polls decays gradually', () async {
    await poll(-80);
    await poll(-10);
    final afterLoud = levels.length;
    for (var i = 0; i < 6; i++) {
      await poll(-80);
    }
    final fall = levels.sublist(afterLoud - 1);
    expect(fall.first, closeTo(0.9, 0.03));
    expect(fall[1], greaterThan(0.6));
    expect(
      fall,
      orderedEquals(
        fall.toList()..sort((double a, double b) => b.compareTo(a)),
      ),
    );
    expect(fall.toSet().length, greaterThanOrEqualTo(4));
    expect(fall.last, inInclusiveRange(0.3, 0.5));
  });
}
