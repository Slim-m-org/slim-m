// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clip another member plays: who hears it on this device, and at what level.
///
/// The server sends one `soundboard.played` to each person in the call, so the
/// only decision left to the client is whether to stay silent.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/sound_clip_player.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_clips.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_player.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_settings.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';

import '../../support/fake_voice.dart';
import 'voice_controller_harness.dart' show FakeSession;

class _RecordingPlayer implements SoundClipPlayer {
  final played = <({Uint8List bytes, String mimeType, double volume})>[];

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async => played.add((bytes: bytes, mimeType: mimeType, volume: volume));
}

const _played = api.SoundboardPlayed(
  channelId: 'c1',
  clipId: 'clip-1',
  playerId: 'user-bob',
);

class _Rig {
  _Rig({bool soundsOn = true, this.failingFetches = 0}) {
    SharedPreferences.setMockInitialValues({
      soundboardSoundsEnabledKey: soundsOn,
    });
    container = ProviderContainer(
      overrides: [
        liveEventsProvider.overrideWithValue(events.stream),
        soundClipPlayerProvider.overrideWithValue(player),
        soundClipAudioProvider.overrideWith((ref, id) async {
          fetches++;
          if (fetches <= failingFetches) {
            throw const api.TransportException('offline');
          }
          return api.FetchedBytes(
            bytes: Uint8List.fromList([1, 2, 3]),
            contentType: 'audio/wav',
          );
        }),
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(ref, session: session),
        ),
      ],
    );
    container.read(soundboardSoundsProvider);
    container.read(soundboardPlayerProvider);
    voice.connect();
  }

  final int failingFetches;
  var fetches = 0;
  final events = StreamController<api.ServerEvent>.broadcast();
  final player = _RecordingPlayer();
  final session = FakeSession();
  late final ProviderContainer container;

  FakeVoiceController get voice =>
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;

  Future<void> hear([api.SoundboardPlayed event = _played]) async {
    events.add(event);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Future<void> dispose() async {
    container.dispose();
    await events.close();
  }
}

Future<_Rig> _rig({bool soundsOn = true, int failingFetches = 0}) async {
  final rig = _Rig(soundsOn: soundsOn, failingFetches: failingFetches);
  addTearDown(rig.dispose);
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return rig;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a clip played in this call plays once, from the cached bytes',
    () async {
      final rig = await _rig();
      await rig.hear();
      expect(rig.player.played, hasLength(1));
      expect(rig.player.played.single.bytes, [1, 2, 3]);
      expect(rig.player.played.single.mimeType, 'audio/wav');
      expect(rig.player.played.single.volume, 1.0);
    },
  );

  test('a clip whose audio failed to load plays on the next try', () async {
    final rig = await _rig(failingFetches: 1);
    await rig.hear();
    expect(rig.player.played, isEmpty);
    await rig.hear();
    expect(rig.player.played, hasLength(1), reason: 'the failure was not kept');
    expect(rig.fetches, 2);
  });

  test('a clip for a call this device is not in is ignored', () async {
    final rig = await _rig();
    await rig.hear(
      const api.SoundboardPlayed(
        channelId: 'elsewhere',
        clipId: 'clip-1',
        playerId: 'user-bob',
      ),
    );
    expect(rig.player.played, isEmpty);
  });

  test('deafened plays nothing, and undeafened plays again', () async {
    final rig = await _rig();
    rig.voice.update((s) => s.copyWith(deafened: true));
    await rig.hear();
    expect(rig.player.played, isEmpty);

    rig.voice.update((s) => s.copyWith(deafened: false));
    await rig.hear();
    expect(rig.player.played, hasLength(1));
  });

  test('the soundboard sounds switch off plays nothing', () async {
    final rig = await _rig(soundsOn: false);
    await rig.hear();
    expect(rig.player.played, isEmpty);

    await rig.container
        .read(soundboardSoundsProvider.notifier)
        .setEnabled(true);
    await rig.hear();
    expect(rig.player.played, hasLength(1));
  });

  test('someone muted for this listener is silent', () async {
    final rig = await _rig();
    await rig.session.setLocallyMuted('user-bob', true);
    await rig.hear();
    expect(rig.player.played, isEmpty);
  });

  test("the player's own volume scales the clip", () async {
    final rig = await _rig();
    await rig.session.setVolumeFor('user-bob', 0.5);
    await rig.hear();
    expect(rig.player.played.single.volume, closeTo(0.125, 1e-9));

    await rig.session.setVolumeFor('user-bob', 0);
    await rig.hear();
    expect(rig.player.played.last.volume, 0);
  });

  test('a volume above the default never plays louder than the clip', () async {
    final rig = await _rig();
    await rig.session.setVolumeFor('user-bob', 2);
    await rig.hear();
    expect(rig.player.played.single.volume, 1.0);
  });
}
