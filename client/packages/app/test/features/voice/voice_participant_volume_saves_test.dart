// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two quick volume releases both land in the saved map, and a failed save is logged, not thrown.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  test('overlapping releases for two people both persist', () async {
    final controller = harness.controllerWith(FakeSession(), voiceApi());

    await Future.wait([
      controller.volumes.setVolumeFor('ann', 0.5),
      controller.volumes.setVolumeFor('bob', 0.25),
    ]);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefs.getString('slimm.voice.participant_volumes')!,
    );
    expect(saved, {'ann': 0.5, 'bob': 0.25});
  });

  test('a failed save does not escape as an uncaught error', () async {
    final controller = harness.controllerWith(
      FakeSession(),
      voiceApi(),
      extraOverrides: [
        preferencesProvider.overrideWith(
          (ref) => throw StateError('disk full'),
        ),
      ],
    );

    await controller.volumes.setVolumeFor('ann', 0.5);
    await pumpEventQueue();
  });
}
