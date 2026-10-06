// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera toggle shows as pending while the camera opens, and a second press
/// meanwhile does not race the first. Opening a webcam can take seconds.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'voice_controller_harness.dart';

class _HeldCameraSession extends FakeSession {
  _HeldCameraSession();

  Completer<bool> open = Completer<bool>();
  int cameraCalls = 0;

  @override
  Future<bool> setCameraEnabled(bool enabled) {
    cameraCalls++;
    askedForCameraOnToggle = enabled;
    return open.future;
  }
}

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('the toggle is pending while the camera opens', () async {
    final session = _HeldCameraSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    final toggle = controller.toggleCamera();
    expect(controller.state.cameraPending, isTrue);
    expect(controller.state.cameraEnabled, isFalse);

    session.open.complete(true);
    await toggle;

    expect(controller.state.cameraPending, isFalse);
    expect(controller.state.cameraEnabled, isTrue);
  });

  test('a second press while the camera opens does not reach it', () async {
    final session = _HeldCameraSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    final first = controller.toggleCamera();
    await controller.toggleCamera();
    session.open.complete(true);
    await first;

    expect(session.cameraCalls, 1);
    expect(controller.state.cameraEnabled, isTrue);
  });

  test('a refused open clears the pending state', () async {
    final session = _HeldCameraSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');

    final toggle = controller.toggleCamera();
    session.open.complete(false);
    await toggle;

    expect(controller.state.cameraPending, isFalse);
    expect(controller.state.cameraEnabled, isFalse);
  });
}
