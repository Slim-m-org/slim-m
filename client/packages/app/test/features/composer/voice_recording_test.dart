// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/composer/providers/composer_actions.dart';
import 'package:slimm_app/src/features/composer/providers/voice_capture_record.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';

class FakeCapture implements VoiceCaptureBackend {
  FakeCapture({this.allowed = true});

  final bool allowed;
  double nextLevel = 0.5;
  bool started = false;
  bool cancelled = false;
  bool stopped = false;

  @override
  Future<bool> start() async => started = allowed;

  @override
  Future<double> level() async => nextLevel;

  @override
  Future<VoiceCapture?> stop() async {
    stopped = true;
    return VoiceCapture(
      bytes: Uint8List.fromList([1, 2, 3]),
      filename: 'voice-message.ogg',
    );
  }

  @override
  Future<void> cancel() async => cancelled = true;
}

class FakeActions implements ComposerActions {
  final uploads = <({String channelId, VoiceInfo voice, String filename})>[];
  int failures = 0;

  @override
  Future<Attachment> uploadVoice(
    List<int> bytes, {
    required String filename,
    required String channelId,
    required VoiceInfo voice,
  }) async {
    if (failures > 0) {
      failures--;
      throw const TransportException('boom');
    }
    uploads.add((channelId: channelId, voice: voice, filename: filename));
    return Attachment(
      id: 'abc',
      filename: filename,
      contentType: 'audio/ogg',
      size: bytes.length,
      voice: voice,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Rig {
  Rig({bool allowed = true}) : capture = FakeCapture(allowed: allowed) {
    container = ProviderContainer(
      overrides: [
        voiceCaptureFactoryProvider.overrideWithValue(() => capture),
        composerActionsProvider.overrideWithValue(actions),
      ],
    );
    recorder.now = () => clock;
  }

  final FakeCapture capture;
  final actions = FakeActions();
  late final ProviderContainer container;
  DateTime clock = DateTime(2026, 1, 1);

  VoiceRecorder get recorder =>
      container.read(voiceRecorderProvider('c1').notifier);
  VoiceRecordingState get state => container.read(voiceRecorderProvider('c1'));

  /// Keeps the autodispose provider alive for the test's length.
  void listen() => container.listen(voiceRecorderProvider('c1'), (_, _) {});

  Future<void> advance(Duration by) async {
    clock = clock.add(by);
    await recorder.tick();
  }
}

void main() {
  late Rig rig;

  Future<Rig> started({bool allowed = true}) async {
    rig = Rig(allowed: allowed)..listen();
    addTearDown(rig.container.dispose);
    await rig.recorder.start();
    return rig;
  }

  test('a denied microphone leaves an inline error and no recording', () async {
    await started(allowed: false);
    expect(rig.state.phase, VoicePhase.failed);
    expect(rig.state.error, contains('Microphone access is off'));
    expect(rig.state.clip, isNull);
  });

  test('recording shows the running clock and the newest levels', () async {
    await started();
    expect(rig.state.phase, VoicePhase.recording);
    rig.capture.nextLevel = 0.25;
    await rig.advance(const Duration(seconds: 2));
    rig.capture.nextLevel = 0.75;
    await rig.advance(const Duration(seconds: 1));
    expect(rig.state.elapsed, const Duration(seconds: 3));
    expect(rig.state.levels, [0.25, 0.75]);
  });

  test('a stray tap shorter than half a second is dropped', () async {
    await started();
    await rig.advance(const Duration(milliseconds: 200));
    await rig.recorder.stop();
    expect(rig.state.phase, VoicePhase.idle);
    expect(rig.state.clip, isNull);
  });

  test('the five minute cap stops the recording and keeps the clip', () async {
    await started();
    await rig.advance(const Duration(minutes: 4, seconds: 59));
    expect(rig.state.phase, VoicePhase.recording);
    await rig.advance(const Duration(seconds: 1));
    expect(rig.state.phase, VoicePhase.stopped);
    expect(rig.state.hitCap, isTrue);
    expect(rig.state.clip!.duration, kVoiceMaxDuration);
    expect(rig.capture.stopped, isTrue);
  });

  test('a clock past the cap never records longer than the cap', () async {
    await started();
    await rig.advance(const Duration(minutes: 7));
    expect(rig.state.clip!.duration, kVoiceMaxDuration);
  });

  test('discarding releases the microphone and goes back to idle', () async {
    await started();
    await rig.advance(const Duration(seconds: 2));
    await rig.recorder.cancel();
    expect(rig.capture.cancelled, isTrue);
    expect(rig.state.phase, VoicePhase.idle);
  });

  test(
    'closing the composer while recording releases the microphone',
    () async {
      await started();
      rig.container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(rig.capture.cancelled, isTrue);
    },
  );

  test('send uploads the clip as a voice message in its channel', () async {
    await started();
    rig.capture.nextLevel = 1;
    await rig.advance(const Duration(seconds: 3));
    final sent = await rig.recorder.send();
    final upload = rig.actions.uploads.single;
    expect(upload.channelId, 'c1');
    expect(upload.filename, 'voice-message.ogg');
    expect(upload.voice.duration, const Duration(seconds: 3));
    expect(upload.voice.waveform, hasLength(VoiceInfo.buckets));
    expect(sent!.$1.id, 'abc');
    expect(sent.$2, [1, 2, 3]);
    expect(rig.state.phase, VoicePhase.idle);
  });

  test('a failed upload keeps the clip so Send can try again', () async {
    await started();
    await rig.advance(const Duration(seconds: 3));
    rig.actions.failures = 1;
    expect(await rig.recorder.send(), isNull);
    expect(rig.state.phase, VoicePhase.failed);
    expect(rig.state.error, isNotNull);
    expect(rig.state.clip, isNotNull);
    expect(await rig.recorder.send(), isNotNull);
    expect(rig.state.phase, VoicePhase.idle);
  });

  group('buildWaveform', () {
    test('is always 64 buckets, the loudest reaching the top', () {
      final bars = buildWaveform([for (var i = 0; i < 300; i++) i / 600]);
      expect(bars, hasLength(64));
      expect(bars.reduce((a, b) => a > b ? a : b), 255);
    });

    test('a clip shorter than the bar count still fills every bucket', () {
      final bars = buildWaveform([0.5, 1.0]);
      expect(bars, hasLength(64));
      expect(bars.first, lessThan(bars.last));
    });

    test('silence stays silent instead of being stretched', () {
      expect(
        buildWaveform(List.filled(100, 0.01)).every((v) => v < 10),
        isTrue,
      );
      expect(buildWaveform(const []), everyElement(0));
    });
  });

  test('only Android and Linux record Opus', () {
    for (final platform in TargetPlatform.values) {
      expect(
        prefersOpus(platform, isWeb: false),
        platform == TargetPlatform.android || platform == TargetPlatform.linux,
        reason: '$platform',
      );
    }
    expect(prefersOpus(TargetPlatform.linux, isWeb: true), isFalse);
  });
}
