// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the real capture backend asks the `record` plugin for: the format
/// every client can play, from the microphone picked in Voice settings.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/providers/voice_capture_record.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_storage.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_rtc/rtc.dart' show AudioDevice;

import '../../support/dead_voice_session.dart';
import '../../support/fake_voice.dart';

/// Answers the plugin calls a recording makes and keeps what [start] was given.
class FakeRecordPlatform extends RecordPlatform {
  FakeRecordPlatform({this.devices = const [], this.listingFails = false});

  final List<InputDevice> devices;
  final bool listingFails;
  RecordConfig? config;
  String? path;
  bool stopFails = false;
  int disposals = 0;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder e) async =>
      true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    if (listingFails) throw PlatformException(code: 'record');
    return devices;
  }

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    this.config = config;
    this.path = path;
  }

  /// The raw samples a stream take hands out, while one runs.
  StreamController<Uint8List>? samples;

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    this.config = config;
    return (samples = StreamController<Uint8List>()).stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    if (stopFails) throw PlatformException(code: 'record');
    return null;
  }

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<void> dispose(String recorderId) async => disposals++;

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A call's own microphone list, as Voice settings shows it.
class _Mics extends DeadVoiceSession {
  _Mics({required this.selectable});

  final bool selectable;

  @override
  bool get supportsAudioInputSelection => selectable;

  @override
  Future<List<AudioDevice>> audioInputDevices() async => const [
    AudioDevice(id: 'pulse:alsa_input.usb-headset', label: 'Headset'),
  ];
}

Future<AudioDevice?> _resolve({String? saved, bool selectable = true}) async {
  SharedPreferences.setMockInitialValues({
    if (saved != null) VoiceSettingKeys.audioInputDeviceId: saved,
  });
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      voiceControllerProvider.overrideWith(
        (ref) =>
            FakeVoiceController(ref, session: _Mics(selectable: selectable)),
      ),
    ],
  );
  addTearDown(container.dispose);
  final probe = FutureProvider((ref) => chosenVoiceInput(ref));
  return container.read(probe.future);
}

const _builtIn = InputDevice(
  id: 'alsa_input.pci-0000',
  label: 'Built-in Audio',
);
const _headset = InputDevice(id: 'alsa_input.usb-headset', label: 'Headset');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordPlatform original;

  setUp(() {
    original = RecordPlatform.instance;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/voice-capture-test',
        );
  });

  tearDown(() {
    RecordPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  test('a stop the plugin refuses still releases the recorder', () async {
    final platform = FakeRecordPlatform()..stopFails = true;
    RecordPlatform.instance = platform;
    final capture = RecordVoiceCapture();
    expect(await capture.start(), isTrue);
    await expectLater(capture.stop(), throwsA(isA<PlatformException>()));
    expect(platform.disposals, 1);
  });

  Future<FakeRecordPlatform> startWith({
    AudioDevice? chosen,
    List<InputDevice> devices = const [_builtIn, _headset],
    bool listingFails = false,
  }) async {
    final platform = FakeRecordPlatform(
      devices: devices,
      listingFails: listingFails,
    );
    RecordPlatform.instance = platform;
    final capture = RecordVoiceCapture(chosenInput: () async => chosen);
    expect(await capture.start(), isTrue);
    return platform;
  }

  test('every platform but Linux has the plugin record 16 kHz mono WAV, which '
      'every client plays', () async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final target in TargetPlatform.values) {
      if (target == TargetPlatform.linux) continue;
      debugDefaultTargetPlatformOverride = target;
      final platform = await startWith();
      expect(platform.config!.encoder, AudioEncoder.wav, reason: '$target');
      expect(platform.config!.sampleRate, 16000, reason: '$target');
      expect(platform.config!.numChannels, 1, reason: '$target');
      expect(platform.path, endsWith('.wav'), reason: '$target');
    }
  });

  group('on Linux, where the plugin writes files only through ffmpeg', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('takes raw 16 kHz mono samples instead of a file', () async {
      final platform = await startWith();
      expect(platform.config!.encoder, AudioEncoder.pcm16bits);
      expect(platform.config!.sampleRate, 16000);
      expect(platform.config!.numChannels, 1);
      expect(platform.path, isNull);
    });

    test('stops with those samples as a WAV every client plays', () async {
      final platform = FakeRecordPlatform();
      RecordPlatform.instance = platform;
      final capture = RecordVoiceCapture();
      await capture.start();
      platform.samples!
        ..add(Uint8List.fromList([1, 2, 3]))
        ..add(Uint8List.fromList([4, 5, 6, 7]));
      await Future<void>.delayed(Duration.zero);

      final clip = (await capture.stop())!;

      final wav = ByteData.sublistView(clip.bytes);
      expect(clip.filename, 'voice-message.wav');
      expect(String.fromCharCodes(clip.bytes.sublist(0, 4)), 'RIFF');
      expect(wav.getUint32(4, Endian.little), clip.bytes.length - 8);
      expect(String.fromCharCodes(clip.bytes.sublist(8, 16)), 'WAVEfmt ');
      expect(wav.getUint16(20, Endian.little), 1, reason: 'PCM');
      expect(wav.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(wav.getUint32(24, Endian.little), 16000);
      expect(wav.getUint32(28, Endian.little), 32000, reason: 'bytes/s');
      expect(wav.getUint16(32, Endian.little), 2, reason: 'block align');
      expect(wav.getUint16(34, Endian.little), 16, reason: 'bits');
      expect(String.fromCharCodes(clip.bytes.sublist(36, 40)), 'data');
      expect(wav.getUint32(40, Endian.little), 6, reason: 'whole frames');
      expect(clip.bytes.sublist(44), [1, 2, 3, 4, 5, 6]);
      expect(platform.disposals, 1);
    });
  });

  test('records from the sound server node picked in Voice settings', () async {
    final platform = await startWith(
      chosen: const AudioDevice(id: 'pulse:alsa_input.usb-headset', label: ''),
    );
    expect(platform.config!.device?.id, _headset.id);
  });

  test('a pick the plugin names differently is found by its name', () async {
    final platform = await startWith(
      chosen: const AudioDevice(id: '{0.0.1}.{abc}', label: 'Headset'),
    );
    expect(platform.config!.device?.id, _headset.id);
  });

  test('an unplugged pick, or none, records from the default', () async {
    for (final chosen in [
      null,
      const AudioDevice(id: 'pulse:gone', label: 'Old webcam'),
    ]) {
      final platform = await startWith(chosen: chosen);
      expect(platform.config!.device, isNull, reason: '$chosen');
    }
  });

  test('a device list that cannot be read records from the default', () async {
    final platform = await startWith(
      chosen: const AudioDevice(id: 'pulse:alsa_input.usb-headset', label: ''),
      listingFails: true,
    );
    expect(platform.config!.device, isNull);
  });

  group('the pick a voice message records from', () {
    test('is the microphone saved in Voice settings, with its name', () async {
      final chosen = await _resolve(saved: 'pulse:alsa_input.usb-headset');
      expect(chosen?.id, 'pulse:alsa_input.usb-headset');
      expect(chosen?.label, 'Headset');
    });

    test('keeps a pick the call does not list by its id alone', () async {
      final chosen = await _resolve(saved: 'pulse:elsewhere');
      expect(chosen?.id, 'pulse:elsewhere');
      expect(chosen?.label, isEmpty);
    });

    test(
      'is the default with no pick, or where a pick changes nothing',
      () async {
        expect(await _resolve(), isNull);
        expect(
          await _resolve(
            saved: 'pulse:alsa_input.usb-headset',
            selectable: false,
          ),
          isNull,
        );
      },
    );
  });
}
