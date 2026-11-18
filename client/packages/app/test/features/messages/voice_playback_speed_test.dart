// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The chosen speed is the speed the clip really plays at: from the first
/// moment, after a pause, after a seek, for the next clip, and when it is
/// chosen while a clip is still opening.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';

import 'voice_player_fakes.dart';

/// Plays the way the browser and GStreamer do: opening a clip resets the rate
/// to 1x, and a rate set with no clip open never reaches the audio.
class _RateEngine implements AudioPlayer {
  double heard = 1;
  bool _open = false;

  @override
  Future<void> stop() async => _open = false;

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    _open = true;
    heard = 1;
  }

  @override
  Future<void> setPlaybackRate(double playbackRate) async {
    if (_open) heard = playbackRate;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();

  @override
  Stream<void> get onPlayerComplete => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds each play until told, like a real engine still opening its source.
class _SlowPlayer extends FakePlayer {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> play(Uint8List bytes, String mimeType, double speed) async {
    started.complete();
    await release.future;
    await super.play(bytes, mimeType, speed);
  }
}

void main() {
  final clip = Uint8List.fromList([1, 2, 3, 4]);
  late _RateEngine engine;
  late AudioPlayersVoiceBackend backend;

  setUp(() {
    engine = _RateEngine();
    backend = AudioPlayersVoiceBackend(player: () => engine);
  });

  test('a clip started at 2x plays at 2x', () async {
    await backend.play(clip, 'audio/wav', 2);
    expect(engine.heard, 2);
  });

  test('the next clip keeps the chosen speed', () async {
    await backend.play(clip, 'audio/wav', 1.5);
    await backend.play(clip, 'audio/wav', 1.5);
    expect(engine.heard, 1.5);
  });

  test('a pause and resume, then a seek, keep 2x', () async {
    await backend.play(clip, 'audio/wav', 2);
    await backend.pause();
    await backend.resume();
    expect(engine.heard, 2, reason: 'after resume');
    await backend.seek(const Duration(seconds: 3));
    expect(engine.heard, 2, reason: 'after seek');
  });

  test('a speed chosen while playing changes it', () async {
    await backend.play(clip, 'audio/wav', 1);
    await backend.setSpeed(2);
    expect(engine.heard, 2);
  });

  test('a speed chosen while the clip is still opening reaches it', () async {
    final slow = _SlowPlayer();
    final c = ProviderContainer(
      overrides: [
        voicePlaybackProvider.overrideWith(() => VoicePlayback(ios: false)),
        voicePlayerFactoryProvider.overrideWithValue(() => slow),
        attachmentBytesProvider.overrideWith((ref, id) async => clip),
      ],
    );
    addTearDown(c.dispose);
    final playback = c.read(voicePlaybackProvider.notifier);

    final starting = playback.toggle(voiceMessage('a'));
    await slow.started.future;
    await playback.cycleSpeed();
    slow.release.complete();
    await starting;

    expect(c.read(voicePlaybackProvider).speed, 1.5);
    expect(slow.speed, 1.5);
  });
}
