// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong adds rnnoise natively while libwebrtc's own suppression stays on, so
/// choosing it never touches the capture options.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('the capture keeps libwebrtc suppression on, with or without Strong',
      () {
    final switching = AudioDeviceSwitching(const _NoDevices());
    final options = switching.captureOptions();
    expect(options.noiseSuppression, isTrue);
    expect(options.echoCancellation, isTrue);
    expect(options.autoGainControl, isTrue);
    expect(options.stopAudioCaptureOnMute, isFalse);
    final room = switching.roomOptions(const lk.RoomOptions());
    expect(room.defaultAudioCaptureOptions.noiseSuppression, isTrue);
  });

  test('choosing Strong reconfigures the gate and nothing else', () {
    var changes = 0;
    final strong = StrongNoiseSuppression(
      supported: true,
      onChanged: () => changes++,
    );
    expect(strong.nativeStrong, isFalse);
    expect(strong.watching, isFalse);
    strong.setStrong(true);
    strong.setStrong(true);
    expect(strong.nativeStrong, isTrue);
    expect(strong.watching, isTrue);
    expect(changes, 1);
    strong.setStrong(false);
    expect(strong.nativeStrong, isFalse);
    expect(changes, 2);
  });

  test('a host without the native gate never watches for rnnoise', () {
    final strong = StrongNoiseSuppression(supported: false, onChanged: () {})
      ..setStrong(true);
    expect(strong.watching, isFalse);
  });
}

class _NoDevices implements AudioDevices {
  const _NoDevices();

  @override
  Future<List<AudioDevice>> inputs() async => const [];

  @override
  Future<List<AudioDevice>> outputs() async => const [];

  @override
  Future<AudioDevice?> systemDefaultInput() async => null;

  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;

  @override
  Stream<void> get onChange => const Stream.empty();
}
