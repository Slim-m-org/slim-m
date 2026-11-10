// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the host has no input gate, the dock's level bar follows the level
/// the SFU reports for you; it no longer rides the roster, which a level tick
/// must not change.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

import 'voice_settings_screen_harness.dart';

void main() {
  late FakeSettingsSession session;
  late ProviderContainer container;
  final levels = <double>[];

  setUp(() {
    levels.clear();
    session = FakeSettingsSession();
    container = ProviderContainer(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    );
    container.listen<double>(
      localMicLevelProvider,
      (_, next) => levels.add(next),
      fireImmediately: true,
    );
    addTearDown(() async {
      container.dispose();
      await session.dispose();
    });
  });

  Future<void> report(double level) async {
    session.localLevelController.add(level);
    await pumpEventQueue();
  }

  test('the bar starts empty and follows the reported level', () async {
    expect(levels, [0.0]);

    await report(0.5);
    await report(0.8);

    expect(levels, [0.0, 0.5, 0.8]);
  });

  test(
    'a level within one step of the last does not repaint the bar',
    () async {
      await report(0.5);
      await report(0.52);
      await report(0.48);

      expect(levels, [0.0, 0.5]);
    },
  );

  test('the bar falls back to empty when the level does', () async {
    await report(0.7);
    await report(0);

    expect(levels.last, 0.0);
  });
}
