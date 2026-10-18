// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [resolveAudioDevice] and the [AudioDevices] seam: a fake stands
/// in for [HardwareAudioDevices] the same way `_FixedCameraDevices` stands in
/// for `HardwareCameraDevices` in `camera_devices_test.dart`.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _FakeAudioDevices implements AudioDevices {
  _FakeAudioDevices({
    this.inputDevices = const [],
    this.outputDevices = const [],
  });

  final List<AudioDevice> inputDevices;
  final List<AudioDevice> outputDevices;
  final _changes = StreamController<void>.broadcast();

  @override
  Future<List<AudioDevice>> inputs() async => inputDevices;

  @override
  Future<List<AudioDevice>> outputs() async => outputDevices;

  @override
  Future<AudioDevice?> systemDefaultInput() async =>
      inputDevices.where((d) => d.id == 'default').firstOrNull;

  @override
  Future<AudioDevice?> systemDefaultOutput() async =>
      outputDevices.where((d) => d.id == 'default').firstOrNull;

  @override
  Stream<void> get onChange => _changes.stream;

  void fireChange() => _changes.add(null);

  void dispose() => _changes.close();
}

void main() {
  group('withoutPseudoDefaults', () {
    test('drops the browser stand-ins and keeps every real device', () {
      const real = AudioDevice(id: 'abc', label: 'Headset');
      final kept = withoutPseudoDefaults(const [
        AudioDevice(id: 'default', label: 'Default'),
        AudioDevice(id: 'communications', label: 'Communications'),
        real,
      ]);
      expect(kept, [real]);
    });

    test('drops the unnamed entries a browser lists before it has the mic', () {
      const real = AudioDevice(id: 'abc', label: 'Headset');
      expect(
        withoutPseudoDefaults(const [AudioDevice(id: '', label: ''), real]),
        [real],
      );
    });
  });

  group('resolveAudioDevice', () {
    const devices = [
      AudioDevice(id: 'mic-1', label: 'Built-in microphone'),
      AudioDevice(id: 'mic-2', label: 'USB headset'),
    ];

    test('a null preference always means the system default', () {
      expect(resolveAudioDevice(devices, null), isNull);
    });

    test('a preferred id present in the list resolves to that device', () {
      expect(resolveAudioDevice(devices, 'mic-2')!.label, 'USB headset');
    });

    test(
      'a preferred id no longer in the list falls back to the default, '
      'the same as an unplugged device',
      () {
        expect(resolveAudioDevice(devices, 'mic-unplugged'), isNull);
      },
    );

    test('an empty device list always falls back to the default', () {
      expect(resolveAudioDevice(const [], 'mic-1'), isNull);
    });
  });

  group('AudioDevices fake', () {
    test('lists inputs and outputs independently', () async {
      final devices = _FakeAudioDevices(
        inputDevices: const [AudioDevice(id: 'mic-1', label: 'Mic')],
        outputDevices: const [AudioDevice(id: 'spk-1', label: 'Speaker')],
      );
      addTearDown(devices.dispose);

      expect((await devices.inputs()).single.id, 'mic-1');
      expect((await devices.outputs()).single.id, 'spk-1');
    });

    test('onChange fires for a caller listening for a device hotplug',
        () async {
      final devices = _FakeAudioDevices();
      addTearDown(devices.dispose);

      final fired = expectLater(devices.onChange, emits(null));
      devices.fireChange();
      await fired;
    });
  });
}
