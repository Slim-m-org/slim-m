// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux sound server path for picking a microphone or speaker, used
/// where libwebrtc lists no audio devices (owner's box, 2026-10-15).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

/// The shape `pactl -f json list sources` prints, trimmed to what matters.
final _sources = jsonEncode([
  {
    'index': 66,
    'name': 'alsa_input.usb-EMEET_C960.analog-stereo',
    'description': 'EMEET SmartCam C960 4K Analog Stereo',
    'monitor_source': ''
  },
  {
    'index': 115,
    'name': 'sink_game.monitor',
    'description': 'Monitor of Main',
    'monitor_source': 'sink_game'
  },
  {
    'index': 12894,
    'name': 'sink_mic',
    'description': 'Clean Mic',
    'monitor_source': ''
  },
  {'index': 7, 'name': 'nameless', 'description': '', 'monitor_source': ''},
]);

final _sinks = jsonEncode([
  {
    'index': 943,
    'name': 'alsa_output.usb-Arctis.analog-stereo',
    'description': 'Arctis Nova Pro Wireless Analog Stereo'
  },
]);

final _sourceOutputs = jsonEncode([
  {
    'index': 82,
    'source': 944,
    'properties': {'application.process.id': '111'}
  },
  {
    'index': 500,
    'source': 944,
    'properties': {'application.process.id': '4242'}
  },
  {'index': 501, 'source': 944, 'properties': <String, String>{}},
]);

final _sinkInputs = jsonEncode([
  {
    'index': 600,
    'sink': 943,
    'properties': {'application.process.id': '4242'}
  },
]);

class _FakePactl {
  final calls = <List<String>>[];

  Future<ProcessResult> call(List<String> args) async {
    calls.add(args);
    final out = switch (args) {
      ['-f', 'json', 'list', 'sources'] => _sources,
      ['-f', 'json', 'list', 'sinks'] => _sinks,
      ['-f', 'json', 'list', 'source-outputs'] => _sourceOutputs,
      ['-f', 'json', 'list', 'sink-inputs'] => _sinkInputs,
      ['get-default-source'] => 'sink_mic\n',
      _ => '',
    };
    return ProcessResult(0, 0, out, '');
  }

  List<List<String>> get moves =>
      calls.where((c) => c.first.startsWith('move-')).toList();
}

class _NoDevices implements AudioDevices {
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

void main() {
  test('only a device appearing, going or the default moving is a change', () {
    expect(isDeviceEvent("Event 'new' on source #70"), isTrue);
    expect(isDeviceEvent("Event 'remove' on sink #12"), isTrue);
    expect(isDeviceEvent("Event 'change' on server"), isTrue);
    expect(isDeviceEvent("Event 'change' on source #70"), isFalse);
    expect(isDeviceEvent("Event 'new' on source-output #5"), isFalse);
    expect(isDeviceEvent("Event 'new' on sink-input #5"), isFalse);
  });

  test('a hot-plug reaches the app as a change, volume noise does not',
      () async {
    final pulse = PulseAudio(
      run: _FakePactl().call,
      subscribe: () => Stream.fromIterable([
        "Event 'change' on source #70",
        "Event 'new' on source #71",
        "Event 'remove' on source #71",
      ]),
    );

    expect(await pulse.deviceChanges.length, 2);
  });

  test('on Linux the picker lists the sound server, not libwebrtc', () async {
    final devices = HardwareAudioDevices(
      pulse: PulseAudio(run: _FakePactl().call),
    );

    expect((await devices.inputs()).map((d) => d.id), [
      'pulse:alsa_input.usb-EMEET_C960.analog-stereo',
      'pulse:sink_mic',
      'pulse:nameless',
    ]);
    expect((await devices.outputs()).single.id.startsWith('pulse:'), isTrue);
    expect(await devices.systemDefaultInput(), isNull);
  });

  test('sources leave out sink monitors and fall back to the node name', () {
    final devices = parseSources(_sources);
    expect(devices.map((d) => d.label), [
      'EMEET SmartCam C960 4K Analog Stereo',
      'Clean Mic',
      'nameless',
    ]);
    expect(devices.every((d) => isPulseDeviceId(d.id)), isTrue);
    expect(devices[1].id, 'pulse:sink_mic');
  });

  test('sinks are listed by description', () {
    expect(parseSinks(_sinks).single.label,
        'Arctis Nova Pro Wireless Analog Stereo');
  });

  test('only this process own streams are picked out', () {
    expect(ownStreamIds(_sourceOutputs, 4242), [500]);
    expect(ownStreamIds(_sourceOutputs, 9), isEmpty);
    expect(ownStreamIds('not json at all', 4242), isEmpty);
  });

  test('a move touches only this process own capture stream', () async {
    final pactl = _FakePactl();
    final pulse = PulseAudio(run: pactl.call, processId: 4242);
    expect(
        await pulse.moveOwnStreams(capture: true, deviceId: 'pulse:sink_mic'),
        isTrue);
    expect(pactl.moves, [
      ['move-source-output', '500', 'sink_mic'],
    ]);
  });

  test('a missing pactl reads as no list rather than an empty one', () async {
    final pulse =
        PulseAudio(run: (_) async => throw const ProcessException('pactl', []));
    expect(await pulse.sources(), isNull);
  });

  test(
      'a sound server pick never reaches libwebrtc and is applied by moving streams',
      () async {
    final pactl = _FakePactl();
    final switching = AudioDeviceSwitching(
      _NoDevices(),
      pulse: PulseAudio(run: pactl.call, processId: 4242),
    );
    await switching.selectInput(
        null, const AudioDevice(id: 'pulse:sink_mic', label: 'Clean Mic'));
    await switching.selectOutput(
      null,
      const AudioDevice(
          id: 'pulse:alsa_output.usb-Arctis.analog-stereo', label: 'Arctis'),
    );
    final options = switching.roomOptions(const lk.RoomOptions());
    expect(options.defaultAudioCaptureOptions.deviceId, isNull);
    expect(options.defaultAudioOutputOptions.deviceId, isNull);

    await switching.applyServerRouting();
    expect(pactl.moves, [
      ['move-source-output', '500', 'sink_mic'],
      ['move-sink-input', '600', 'alsa_output.usb-Arctis.analog-stereo'],
    ]);
  });

  test('a libwebrtc pick is left alone by the sound server routing', () async {
    final pactl = _FakePactl();
    final switching = AudioDeviceSwitching(
      _NoDevices(),
      pulse: PulseAudio(run: pactl.call, processId: 4242),
    );
    await switching.selectInput(
        null, const AudioDevice(id: 'webrtc-id', label: 'Mic'));
    expect(
        switching
            .roomOptions(const lk.RoomOptions())
            .defaultAudioCaptureOptions
            .deviceId,
        'webrtc-id');
    await switching.applyServerRouting();
    expect(pactl.moves, isEmpty);
  });

  test(
    'routePreviewInput moves the preview stream to the default source when none is picked',
    () async {
      final pactl = _FakePactl();
      final switching = AudioDeviceSwitching(
        _NoDevices(),
        pulse: PulseAudio(run: pactl.call, processId: 4242),
      );

      await switching.routePreviewInput(null);
      expect(pactl.moves, [
        ['move-source-output', '500', 'sink_mic'],
      ]);
    },
  );

  test(
    'HardwareAudioDevices systemDefaultInput and systemDefaultOutput use the injected device lists on non-Pulse hosts',
    () async {
      final devices = HardwareAudioDevices(
        pulse: PulseAudio(
          run: (_) async => throw const ProcessException('pactl', []),
        ),
        listInputs: () async => [
          const lk.MediaDevice('default', 'Default mic', 'audioinput', null),
          const lk.MediaDevice('usb-mic', 'USB mic', 'audioinput', null),
        ],
        listOutputs: () async => [
          const lk.MediaDevice(
              'default', 'Default speaker', 'audiooutput', null),
          const lk.MediaDevice('usb-spk', 'USB speaker', 'audiooutput', null),
        ],
      );

      final defaultIn = await devices.systemDefaultInput();
      final defaultOut = await devices.systemDefaultOutput();
      expect(defaultIn?.id, 'default');
      expect(defaultOut?.id, 'default');
    },
  );
}
