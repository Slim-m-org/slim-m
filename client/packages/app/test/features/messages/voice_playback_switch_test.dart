// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing a second voice message stops the first at once, even while the
/// second is still downloading, and the first one ending cannot cancel it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/voice_playback.dart';

import 'voice_player_fakes.dart';

void main() {
  late FakePlayer player;
  late Map<String, Completer<Uint8List>> bytes;

  ProviderContainer container() {
    player = FakePlayer();
    bytes = {'a': Completer()..complete(Uint8List(4)), 'b': Completer()};
    final c = ProviderContainer(
      overrides: [
        voicePlaybackProvider.overrideWith(() => VoicePlayback(ios: false)),
        voicePlayerFactoryProvider.overrideWithValue(() => player),
        attachmentBytesProvider.overrideWith((ref, id) => bytes[id]!.future),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a second message stops the first before its bytes arrive, and the '
      "first one's end does not cancel it", () async {
    final c = container();
    final playback = c.read(voicePlaybackProvider.notifier);
    await playback.toggle(voiceMessage('a'));
    expect(c.read(voicePlaybackProvider).playing, isTrue);

    final second = playback.toggle(voiceMessage('b'));
    await Future<void>.delayed(Duration.zero);
    expect(player.log.last, 'stop', reason: 'a stops as soon as b is chosen');

    player.done.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(voicePlaybackProvider).attachmentId, 'b');
    expect(c.read(voicePlaybackProvider).loading, isTrue);

    bytes['b']!.complete(Uint8List(8));
    await second;
    expect(c.read(voicePlaybackProvider).attachmentId, 'b');
    expect(c.read(voicePlaybackProvider).playing, isTrue);
    expect(player.log.last, startsWith('play 8'));
  });

  test('a second message that fails to load leaves nothing sounding', () async {
    final c = container();
    final playback = c.read(voicePlaybackProvider.notifier);
    await playback.toggle(voiceMessage('a'));

    final second = playback.toggle(voiceMessage('b'));
    bytes['b']!.completeError(StateError('offline'));
    await second;

    expect(c.read(voicePlaybackProvider).errorFor, 'b');
    expect(player.log.where((l) => l == 'stop'), isNotEmpty);
  });
}
