// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/composer/providers/composer_actions.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/fake_voice.dart';

class FakeCapture implements VoiceCaptureBackend {
  FakeCapture({this.allowed = true});

  final bool allowed;
  double nextLevel = 0.5;
  bool started = false;
  bool cancelled = false;
  bool stopped = false;

  bool failsToStart = false;
  bool failsToStop = false;

  /// When set, start waits on it, the way a permission prompt does.
  Future<void>? opening;

  /// When set, stop waits on it, the way an encoder finishing its file does.
  Future<void>? finishing;
  int stops = 0;

  @override
  Future<bool> start() async {
    await opening;
    if (failsToStart) throw StateError('parecord: not found');
    return started = allowed;
  }

  @override
  Future<double> level() async => nextLevel;

  @override
  Future<VoiceCapture?> stop() async {
    stops++;
    await finishing;
    if (failsToStop) throw StateError('parecord exited with 1');
    stopped = true;
    return VoiceCapture(
      bytes: Uint8List.fromList([1, 2, 3]),
      filename: 'voice-message.wav',
    );
  }

  /// When set, cancel waits on it, the way a microphone closing does.
  Future<void>? discarding;

  @override
  Future<void> cancel() async {
    if (discarding case final closing?) await closing;
    cancelled = true;
  }
}

class FakeActions implements ComposerActions {
  final uploads = <({String channelId, VoiceInfo voice, String filename})>[];
  int failures = 0;

  /// When set, the upload waits on it, the way a slow link does.
  Future<void>? storing;

  @override
  Future<Attachment> uploadVoice(
    List<int> bytes, {
    required String filename,
    required String channelId,
    required VoiceInfo voice,
  }) async {
    await storing;
    if (failures > 0) {
      failures--;
      throw const TransportException('boom');
    }
    uploads.add((channelId: channelId, voice: voice, filename: filename));
    return Attachment(
      id: 'abc',
      filename: filename,
      contentType: 'audio/wav',
      size: bytes.length,
      voice: voice,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Rig {
  Rig({
    bool allowed = true,
    bool onLinux = false,
    bool onPhone = false,
    String? callChannel,
    List<Override> overrides = const [],
  }) : capture = FakeCapture(allowed: allowed) {
    container = ProviderContainer(
      overrides: [
        ...overrides,
        voiceRecordingNeedsToolsProvider.overrideWithValue(onLinux),
        voiceRecordingYieldsToCallProvider.overrideWithValue(onPhone),
        voiceCaptureFactoryProvider.overrideWithValue(() => capture),
        composerActionsProvider.overrideWithValue(actions),
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(
            ref,
            initial: VoiceState(
              state: callChannel == null
                  ? VoiceSessionState.idle
                  : VoiceSessionState.connected,
              channelId: callChannel,
            ),
          ),
        ),
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

  test(
    'cancelling while the microphone opens closes it once it is open',
    () async {
      rig = Rig()..listen();
      addTearDown(rig.container.dispose);
      final prompt = Completer<void>();
      rig.capture.opening = prompt.future;
      final starting = rig.recorder.start();
      expect(rig.state.phase, VoicePhase.starting);
      await rig.recorder.cancel();
      prompt.complete();
      await starting;
      expect(rig.capture.cancelled, isTrue);
      expect(
        rig.state.phase,
        VoicePhase.idle,
        reason: 'no recording comes back',
      );
    },
  );

  test('leaving the composer while the microphone opens closes it', () async {
    final rig = Rig();
    final sub = rig.container.listen(voiceRecorderProvider('c1'), (_, _) {});
    final prompt = Completer<void>();
    rig.capture.opening = prompt.future;
    final starting = rig.recorder.start();
    sub.close();
    await Future<void>.delayed(Duration.zero);
    prompt.complete();
    await starting;
    expect(rig.capture.cancelled, isTrue, reason: 'nothing else owns it now');
    rig.container.dispose();
  });

  test(
    'a phone in a call refuses to record and never opens the microphone',
    () async {
      rig = Rig(onPhone: true, callChannel: 'lounge')..listen();
      addTearDown(rig.container.dispose);
      await rig.recorder.start();
      expect(rig.state.phase, VoicePhase.failed);
      expect(rig.state.error, 'Leave the call to record a voice message.');
      expect(rig.capture.started, isFalse);
    },
  );

  test(
    'a call does not stop a desktop recording, nor a phone out of one',
    () async {
      for (final (onPhone, callChannel) in [(false, 'lounge'), (true, null)]) {
        final rig = Rig(onPhone: onPhone, callChannel: callChannel)..listen();
        await rig.recorder.start();
        expect(rig.state.phase, VoicePhase.recording, reason: '$onPhone');
        rig.container.dispose();
      }
    },
  );

  test(
    'a call starting stops a recording and keeps the clip to send',
    () async {
      await started();
      await rig.advance(const Duration(seconds: 3));

      await rig.container.read(callStartYieldsProvider).callStarting();

      expect(rig.capture.stopped, isTrue);
      expect(rig.capture.cancelled, isFalse);
      expect(rig.state.phase, VoicePhase.stopped);
      expect(rig.state.clip?.duration, const Duration(seconds: 3));
      expect(rig.state.stoppedForCall, isTrue);
      expect(await rig.recorder.send(), isNotNull);
      expect(rig.actions.uploads, hasLength(1));
    },
  );

  test(
    'a call starting while the microphone opens drops the recording',
    () async {
      rig = Rig()..listen();
      addTearDown(rig.container.dispose);
      final prompt = Completer<void>();
      rig.capture.opening = prompt.future;
      final starting = rig.recorder.start();

      await rig.container.read(callStartYieldsProvider).callStarting();
      prompt.complete();
      await starting;

      expect(rig.capture.cancelled, isTrue);
      expect(rig.state.phase, VoicePhase.idle);
    },
  );

  test('stopping by hand says nothing about a call', () async {
    await started();
    await rig.advance(const Duration(seconds: 3));
    await rig.recorder.stop();

    expect(rig.state.phase, VoicePhase.stopped);
    expect(rig.state.stoppedForCall, isFalse);
  });

  test('a denied microphone leaves an inline error and no recording', () async {
    await started(allowed: false);
    expect(rig.state.phase, VoicePhase.failed);
    expect(rig.state.error, contains('Microphone access is off'));
    expect(rig.state.clip, isNull);
    expect(rig.capture.cancelled, isTrue);
  });

  test('a Linux start that fails names the program it needs', () async {
    for (final onLinux in [true, false]) {
      final rig = Rig(onLinux: onLinux)..listen();
      rig.capture.failsToStart = true;
      await rig.recorder.start();
      expect(rig.state.phase, VoicePhase.failed);
      expect(rig.state.error!.contains('parecord'), onLinux);
      expect(rig.capture.cancelled, isTrue);
      rig.container.dispose();
    }
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

  test('a discard while the clip is finishing is never sent', () async {
    await started();
    await rig.advance(const Duration(seconds: 3));
    final finish = Completer<void>();
    rig.capture.finishing = finish.future;
    final sending = rig.recorder.send();
    await rig.recorder.cancel();
    finish.complete();
    expect(await sending, isNull);
    expect(rig.state.phase, VoicePhase.idle);
    expect(rig.state.clip, isNull);
    expect(rig.actions.uploads, isEmpty);
  });

  for (final after in ['stored', 'refused', 'failed']) {
    test('a discard during the upload is never sent or brought back '
        '(upload $after)', () async {
      await started();
      await rig.advance(const Duration(seconds: 3));
      final stored = Completer<void>();
      rig.actions.storing = stored.future;
      var full = false;
      final sending = rig.recorder.send(
        refusal: () => full ? 'The tray is full.' : null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(rig.state.phase, VoicePhase.uploading);
      await rig.recorder.cancel();
      full = after == 'refused';
      if (after == 'failed') rig.actions.failures = 1;
      stored.complete();
      expect(await sending, isNull);
      expect(rig.state.phase, VoicePhase.idle);
      expect(rig.state.clip, isNull);
    });
  }

  test(
    'a discard while the cap finishes the clip keeps it discarded',
    () async {
      await started();
      final finish = Completer<void>();
      rig.capture.finishing = finish.future;
      final capping = rig.advance(kVoiceMaxDuration);
      await Future<void>.delayed(Duration.zero);
      await rig.recorder.cancel();
      finish.complete();
      await capping;
      expect(rig.state.phase, VoicePhase.idle);
      expect(rig.state.clip, isNull);
    },
  );

  test(
    'a second send while the clip is finishing stops and uploads once',
    () async {
      await started();
      await rig.advance(const Duration(seconds: 3));
      final finish = Completer<void>();
      rig.capture.finishing = finish.future;
      final first = rig.recorder.send();
      final second = rig.recorder.send();
      finish.complete();
      final sent = await Future.wait([first, second]);
      expect(rig.capture.stops, 1);
      expect(rig.actions.uploads, hasLength(1));
      expect(sent.nonNulls, hasLength(1));
      expect(rig.state.phase, VoicePhase.idle);
    },
  );

  test('a clip that cannot be finished says so and sends nothing', () async {
    await started();
    await rig.advance(const Duration(seconds: 3));
    rig.capture.failsToStop = true;
    expect(await rig.recorder.send(), isNull);
    expect(rig.state.phase, VoicePhase.failed);
    expect(rig.state.error, 'The recording could not be finished.');
    expect(rig.actions.uploads, isEmpty);
    await rig.recorder.cancel();
    expect(rig.state.phase, VoicePhase.idle);
  });

  test('send uploads the clip as a voice message in its channel', () async {
    await started();
    rig.capture.nextLevel = 1;
    await rig.advance(const Duration(seconds: 3));
    final sent = await rig.recorder.send();
    final upload = rig.actions.uploads.single;
    expect(upload.channelId, 'c1');
    expect(upload.filename, 'voice-message.wav');
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
}
