// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each community is its own container, but a call in any of them holds the
/// phone's one audio session: a voice message here gives way to it.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_holds_audio_session.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';

import 'voice_player_fakes.dart';

void main() {
  late FakePlayer player;

  ProviderContainer container({
    required bool ios,
    bool callElsewhere = false,
    CallStartYields? yields,
  }) {
    player = FakePlayer();
    final c = ProviderContainer(
      overrides: [
        voicePlaybackProvider.overrideWith(() => VoicePlayback(ios: ios)),
        voicePlayerFactoryProvider.overrideWithValue(() => player),
        attachmentBytesProvider.overrideWith(
          (ref, id) async => Uint8List.fromList([1, 2, 3, 4]),
        ),
        callInAnotherAccountProvider.overrideWithValue(() => callElsewhere),
        if (yields != null) callStartYieldsProvider.overrideWithValue(yields),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('on iOS a call in another community refuses a message here', () async {
    final c = container(ios: true, callElsewhere: true);
    await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));

    expect(c.read(voicePlaybackProvider).error, VoicePlaybackError.inCall);
    expect(player.log, isEmpty);
  });

  test(
    'another community joining a call pauses a message here on iOS',
    () async {
      final shared = CallStartYields();
      final c = container(ios: true, yields: shared);
      await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));
      expect(c.read(voicePlaybackProvider).playing, isTrue);

      await shared.callStarting();

      expect(player.log.last, 'pause');
      expect(c.read(voicePlaybackProvider).playing, isFalse);
      expect(c.read(voicePlaybackProvider).attachmentId, 'a');
    },
  );

  test('switching away from this community pauses its message', () async {
    final c = container(ios: false);
    await c.read(voicePlaybackProvider.notifier).toggle(voiceMessage('a'));

    c.read(accountActiveProvider.notifier).state = false;
    await Future<void>.delayed(Duration.zero);

    expect(player.log.last, 'pause');
    expect(c.read(voicePlaybackProvider).playing, isFalse);
  });
}
