// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning the camera on opens the webcam picked in an earlier call, when it
/// is still plugged in, and leaves the system default alone otherwise.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _DeskSession extends FakeSession {
  final List<String> selected = [];

  @override
  bool get cameraNeedsSelection => true;

  @override
  Future<List<CameraDevice>> cameraDevices() async => const [
    CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
    CameraDevice(id: 'cam-2', label: 'USB camera'),
  ];

  @override
  Future<bool> selectCameraDevice(CameraDevice device) async {
    selected.add(device.id);
    return true;
  }
}

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('the saved webcam is selected before the camera opens', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.camera_device_id': 'cam-2',
    });
    final session = _DeskSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.toggleCamera();

    expect(session.selected, ['cam-2']);
    expect(controller.state.cameraEnabled, isTrue);
  });

  test('a saved webcam that is gone leaves the default alone', () async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.camera_device_id': 'cam-9',
    });
    final session = _DeskSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    await controller.toggleCamera();

    expect(session.selected, isEmpty);
    expect(controller.state.cameraEnabled, isTrue);
  });
}
