// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The webcam picked in an earlier call is handed to the session at start-up,
/// so both the toggle and "Join with camera on" open it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_controller_harness.dart';

class _RecordingSession extends FakeSession {
  final List<String?> preferred = [];

  @override
  void setPreferredCameraId(String? id) => preferred.add(id);
}

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('the saved webcam id is seeded into the session', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.camera_device_id': 'cam-2',
    });
    final session = _RecordingSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.restoreCameraPreference();

    expect(session.preferred, ['cam-2']);
  });

  test('with nothing saved the session keeps the default', () async {
    SharedPreferences.setMockInitialValues({});
    final session = _RecordingSession();
    final controller = harness.controllerWith(session, voiceApi());

    await controller.restoreCameraPreference();

    expect(session.preferred, [null]);
  });
}
