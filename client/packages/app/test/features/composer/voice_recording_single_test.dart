// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One voice message records at a time: starting one in another channel stops
/// the first, which keeps its clip in its own channel.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/providers/composer_actions.dart';
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';

import 'voice_recording_test.dart' show FakeActions, FakeCapture;

class _Channels {
  _Channels() {
    container = ProviderContainer(
      overrides: [
        voiceRecordingNeedsToolsProvider.overrideWithValue(false),
        voiceRecordingYieldsToCallProvider.overrideWithValue(false),
        voiceCaptureFactoryProvider.overrideWithValue(() {
          final capture = FakeCapture()..opening = nextOpening;
          nextOpening = null;
          return captures[_starting!] = capture;
        }),
        composerActionsProvider.overrideWithValue(FakeActions()),
      ],
    );
  }

  late final ProviderContainer container;
  final captures = <String, FakeCapture>{};
  final _composers = <String, ProviderSubscription<VoiceRecordingState>>{};
  DateTime clock = DateTime(2026, 1, 1);
  String? _starting;

  /// When set, the next microphone waits on it before it opens.
  Future<void>? nextOpening;

  VoiceRecorder recorder(String channelId) =>
      container.read(voiceRecorderProvider(channelId).notifier);
  VoiceRecordingState state(String channelId) =>
      container.read(voiceRecorderProvider(channelId));
  String? get live => container.read(recordingVoiceChannelProvider);

  /// Opens [channelId]'s composer and taps its mic.
  Future<void> record(String channelId) {
    _composers[channelId] = container.listen(
      voiceRecorderProvider(channelId),
      (_, _) {},
    );
    recorder(channelId).now = () => clock;
    _starting = channelId;
    return recorder(channelId).start();
  }

  /// Closes [channelId]'s composer, the way opening another channel does.
  Future<void> leave(String channelId) async {
    _composers.remove(channelId)?.close();
    await pumpEventQueue();
  }

  Future<void> advance(String channelId, Duration by) async {
    clock = clock.add(by);
    await recorder(channelId).tick();
  }
}

void main() {
  late _Channels channels;

  setUp(() {
    channels = _Channels();
    addTearDown(channels.container.dispose);
  });

  test('starting a voice message in another channel stops the first and '
      'keeps its clip there', () async {
    await channels.record('c1');
    await channels.advance('c1', const Duration(seconds: 3));
    await channels.leave('c1');

    final opening = Completer<void>();
    channels.nextOpening = opening.future;
    final c2 = channels.record('c2');
    await pumpEventQueue();
    expect(
      channels.state('c1').phase,
      VoicePhase.stopped,
      reason: 'the first lets go of the microphone before the second opens it',
    );
    opening.complete();
    await c2;

    expect(channels.captures['c1']!.stopped, isTrue);
    expect(channels.captures['c1']!.cancelled, isFalse);
    expect(channels.state('c1').phase, VoicePhase.stopped);
    expect(channels.state('c1').clip?.duration, const Duration(seconds: 3));
    expect(channels.state('c1').stoppedForCall, isFalse);
    expect(channels.state('c2').phase, VoicePhase.recording);
    expect(channels.captures['c2']!.started, isTrue);
  });

  test('the recording channel is named only while it records', () async {
    expect(channels.live, isNull);
    await channels.record('c1');
    expect(channels.live, 'c1');
    await channels.advance('c1', const Duration(seconds: 2));
    await channels.recorder('c1').stop();
    expect(channels.live, isNull, reason: 'a kept clip is not recording');

    await channels.recorder('c1').cancel();
    await channels.record('c1');
    expect(channels.live, 'c1');
    await channels.recorder('c1').cancel();
    expect(channels.live, isNull);
  });

  test(
    'two microphones opening at once leave only the later recording',
    () async {
      final first = Completer<void>();
      final second = Completer<void>();
      channels.nextOpening = first.future;
      final c1 = channels.record('c1');
      channels.nextOpening = second.future;
      final c2 = channels.record('c2');

      first.complete();
      await c1;
      await channels.advance('c1', const Duration(seconds: 2));
      second.complete();
      await c2;
      await pumpEventQueue();

      expect(channels.state('c1').phase, VoicePhase.stopped);
      expect(channels.state('c1').clip?.duration, const Duration(seconds: 2));
      expect(channels.state('c2').phase, VoicePhase.recording);
      expect(channels.live, 'c2');
    },
  );
}
