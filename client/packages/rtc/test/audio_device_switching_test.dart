// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [AudioDeviceSwitching]'s room-free half: everything except
/// [AudioDeviceSwitching.selectInput]/[selectOutput]'s live-room branch,
/// which (like `CameraSwitching.select`/`setVideoInputDevice`) reaches a
/// livekit_client extension method that cannot be overridden from a test
/// room - see `camera_switching_test.dart`'s own scope for the same
/// boundary on the camera side.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _FixedAudioDevices implements AudioDevices {
  const _FixedAudioDevices(
      {this.inputDevices = const [], this.outputDevices = const []});

  final List<AudioDevice> inputDevices;
  final List<AudioDevice> outputDevices;

  @override
  Future<List<AudioDevice>> inputs() async => inputDevices;

  @override
  Future<List<AudioDevice>> outputs() async => outputDevices;

  @override
  Stream<void> get onChange => const Stream.empty();
}

void main() {
  group('AudioDeviceSwitching.roomOptions', () {
    const base = lk.RoomOptions(adaptiveStream: true, dynacast: true);

    test('carries no preferred device by default', () {
      final switching = AudioDeviceSwitching(const _FixedAudioDevices());
      final options = switching.roomOptions(base);
      expect(options.defaultAudioCaptureOptions.deviceId, isNull);
      expect(options.defaultAudioOutputOptions.deviceId, isNull);
      // The rest of base survives the overlay untouched.
      expect(options.adaptiveStream, isTrue);
      expect(options.dynacast, isTrue);
    });

    test(
      'recording no room to switch live still remembers the choice for '
      'the next join',
      () async {
        final switching = AudioDeviceSwitching(const _FixedAudioDevices());
        await switching.selectInput(
          null,
          const AudioDevice(id: 'mic-1', label: 'Mic'),
        );
        await switching.selectOutput(
          null,
          const AudioDevice(id: 'spk-1', label: 'Speaker'),
        );

        final options = switching.roomOptions(base);
        expect(options.defaultAudioCaptureOptions.deviceId, 'mic-1');
        expect(options.defaultAudioOutputOptions.deviceId, 'spk-1');
      },
    );

    test('choosing the system default again clears a remembered device',
        () async {
      final switching = AudioDeviceSwitching(const _FixedAudioDevices());
      await switching.selectInput(
        null,
        const AudioDevice(id: 'mic-1', label: 'Mic'),
      );
      await switching.selectInput(null, null);

      expect(switching.roomOptions(base).defaultAudioCaptureOptions.deviceId,
          isNull);
    });
  });

  group('AudioDeviceSwitching capture options', () {
    const base = lk.RoomOptions();

    test('never stop the capture device on mute, whatever is preferred',
        () async {
      final switching = AudioDeviceSwitching(const _FixedAudioDevices());
      final built = <lk.AudioCaptureOptions>[
        switching.roomOptions(base).defaultAudioCaptureOptions,
      ];
      await switching.selectInput(
        null,
        const AudioDevice(id: 'mic-1', label: 'Mic'),
      );
      built.add(switching.roomOptions(base).defaultAudioCaptureOptions);
      await switching.selectInput(null, null);
      built.add(switching.roomOptions(base).defaultAudioCaptureOptions);

      for (final options in built) {
        expect(options.stopAudioCaptureOnMute, isFalse);
      }
    });
  });

  group('AudioDeviceSwitching.selectInput on a live room', () {
    const mics = _FixedAudioDevices(inputDevices: [
      AudioDevice(id: 'raw-mic', label: 'Raw mic'),
      AudioDevice(id: 'clean-mic', label: 'Cleaned mic'),
    ]);

    test('sends the chosen microphone to the live room, every time', () async {
      final applied = <String>[];
      final switching = AudioDeviceSwitching(
        mics,
        liveInput: (room, device) async => applied.add(device.deviceId),
      );
      final room = lk.Room();
      await switching.selectInput(room, mics.inputDevices[1]);
      await switching.selectInput(room, mics.inputDevices[0]);
      await switching.selectInput(room, mics.inputDevices[1]);

      expect(applied, ['clean-mic', 'raw-mic', 'clean-mic']);
      expect(
        switching
            .roomOptions(const lk.RoomOptions())
            .defaultAudioCaptureOptions
            .deviceId,
        'clean-mic',
      );
    });

    test('the system default reselects the first enumerated microphone',
        () async {
      final applied = <String>[];
      final switching = AudioDeviceSwitching(
        mics,
        liveInput: (room, device) async => applied.add(device.deviceId),
      );
      await switching.selectInput(lk.Room(), null);
      expect(applied, ['raw-mic']);
    });

    test('a pick made before the call reaches the next room, not a live one',
        () async {
      final applied = <String>[];
      final switching = AudioDeviceSwitching(
        mics,
        liveInput: (room, device) async => applied.add(device.deviceId),
      );
      await switching.selectInput(null, mics.inputDevices[1]);
      expect(applied, isEmpty);
      expect(
        switching
            .roomOptions(const lk.RoomOptions())
            .defaultAudioCaptureOptions
            .deviceId,
        'clean-mic',
      );
    });
  });

  group('AudioDeviceSwitching device listing', () {
    test('delegates to the injected seam', () async {
      final switching = AudioDeviceSwitching(
        const _FixedAudioDevices(
          inputDevices: [AudioDevice(id: 'mic-1', label: 'Mic')],
          outputDevices: [AudioDevice(id: 'spk-1', label: 'Speaker')],
        ),
      );

      expect((await switching.inputs()).single.id, 'mic-1');
      expect((await switching.outputs()).single.id, 'spk-1');
    });
  });
}
