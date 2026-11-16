// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On iOS a call and a voice message share one audio session: joining stops
/// the message before the connect, and nothing starts or resumes during the
/// call. Elsewhere a call starting pauses the message, and Play resumes it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/audio/sound_session_release.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

import 'voice_player_fakes.dart';

final _call = StateProvider<VoiceFlags>((ref) => const VoiceFlags());

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
  late FakePlayer player;

  ProviderContainer container({required bool ios, FakePlayer? engine}) {
    player = engine ?? FakePlayer();
    final c = ProviderContainer(
      overrides: [
        voicePlaybackProvider.overrideWith(() => VoicePlayback(ios: ios)),
        voicePlayerFactoryProvider.overrideWithValue(() => player),
        attachmentBytesProvider.overrideWith(
          (ref, id) async => Uint8List.fromList([1, 2, 3, 4]),
        ),
        voiceFlagsProvider.overrideWith((ref) => ref.watch(_call)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  void joinCall(ProviderContainer c) =>
      c.read(_call.notifier).state = const VoiceFlags(channelId: 'lounge');

  test('joining a call on iOS stops a message before the connect', () async {
    final c = container(ios: true);
    final playback = c.read(voicePlaybackProvider.notifier);
    await playback.toggle(voiceMessage('a'));
    expect(c.read(voicePlaybackProvider).playing, isTrue);

    joinCall(c);
    await c.read(soundSessionReleaseProvider)();

    expect(player.log.last, 'stop');
    expect(c.read(voicePlaybackProvider).attachmentId, isNull);
    expect(c.read(voicePlaybackProvider).playing, isFalse);
  });

  test(
    'a play still starting when the call joins is stopped as it lands',
    () async {
      final slow = _SlowPlayer();
      final c = container(ios: true, engine: slow);
      final starting = c
          .read(voicePlaybackProvider.notifier)
          .toggle(voiceMessage('a'));
      await slow.started.future;

      joinCall(c);
      await c.read(soundSessionReleaseProvider)();
      slow.release.complete();
      await starting;

      expect(slow.log.last, 'stop');
      expect(c.read(voicePlaybackProvider).playing, isFalse);
    },
  );

  test('a paused message does not resume inside a call on iOS', () async {
    final c = container(ios: true);
    final playback = c.read(voicePlaybackProvider.notifier);
    final message = voiceMessage('a');
    await playback.toggle(message);
    await playback.toggle(message);
    expect(player.log.last, 'pause');

    joinCall(c);
    await playback.toggle(message);

    expect(player.log, isNot(contains('resume')));
    expect(c.read(voicePlaybackProvider).error, VoicePlaybackError.inCall);
    expect(c.read(voicePlaybackProvider).errorFor, 'a');
  });

  test('a message does not start inside a call on iOS', () async {
    final c = container(ios: true);
    joinCall(c);
    await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));

    expect(player.log, isEmpty);
    expect(c.read(voicePlaybackProvider).error, VoicePlaybackError.inCall);
  });

  test(
    'the note that a call holds the audio goes once the call ends',
    () async {
      final c = container(ios: true);
      c.listen(voicePlaybackProvider, (_, _) {});
      joinCall(c);
      await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));
      expect(c.read(voicePlaybackProvider).error, VoicePlaybackError.inCall);

      c.read(_call.notifier).state = const VoiceFlags();

      expect(c.read(voicePlaybackProvider).error, isNull);
    },
  );

  test('elsewhere a call starting pauses a message where it is', () async {
    final c = container(ios: false);
    final playback = c.read(voicePlaybackProvider.notifier);
    final message = voiceMessage('a');
    await playback.toggle(message);
    player.position.add(const Duration(seconds: 7));
    await Future<void>.delayed(Duration.zero);

    joinCall(c);
    await c.read(callStartYieldsProvider).callStarting();

    expect(player.log.last, 'pause', reason: 'paused, not stopped');
    final paused = c.read(voicePlaybackProvider);
    expect(paused.playing, isFalse);
    expect(paused.attachmentId, 'a');
    expect(paused.position, const Duration(seconds: 7));

    await playback.toggle(message);

    expect(player.log.last, 'resume');
    expect(c.read(voicePlaybackProvider).playing, isTrue);
  });

  test(
    'elsewhere a message still loading when a call starts never plays',
    () async {
      final slow = _SlowPlayer();
      final c = container(ios: false, engine: slow);
      final starting = c
          .read(voicePlaybackProvider.notifier)
          .toggle(voiceMessage('a'));
      await slow.started.future;

      joinCall(c);
      await c.read(callStartYieldsProvider).callStarting();
      slow.release.complete();
      await starting;

      expect(slow.log.last, 'stop');
      expect(c.read(voicePlaybackProvider).playing, isFalse);
    },
  );

  test('elsewhere a message already paused stays as it is', () async {
    final c = container(ios: false);
    final playback = c.read(voicePlaybackProvider.notifier);
    final message = voiceMessage('a');
    await playback.toggle(message);
    await playback.toggle(message);

    await c.read(callStartYieldsProvider).callStarting();

    expect(player.log.skip(1), ['pause']);
  });

  test(
    'a call starting on iOS leaves the stop to the session release',
    () async {
      final c = container(ios: true);
      await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));

      await c.read(callStartYieldsProvider).callStarting();

      expect(player.log, hasLength(1), reason: 'nothing but the play');
      expect(c.read(voicePlaybackProvider).playing, isTrue);
    },
  );
}
