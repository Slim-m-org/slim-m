// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s incoming-DM-call half: a ring loops
/// `call_ring` until answered, declined or timed out, never for a ring this
/// device itself started, never for a call this device is already on, and -
/// the phantom-ring regression this file exists to pin - never for mere
/// voice activity with no ring behind it at all.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/dead_voice_session.dart';

/// A [VoiceController] whose channel can be set directly, with no SFU round
/// trip: this file only ever needs `channelId`, never a real call.
class _FixedChannelVoiceController extends VoiceController {
  _FixedChannelVoiceController(super.ref) : super(session: DeadVoiceSession());

  void setChannel(String channelId) =>
      state = state.copyWith(channelId: channelId);
}

/// Records what a real [AudioPlayersSoundPlayer] would actually do, split
/// into the one-shot family ([play]) and the ring's own loop, rather than
/// just a flat list of sounds - the two run on separate players in the real
/// implementation and this file's whole point is telling them apart.
class _FakePlayer implements SoundPlayer {
  final played = <NotificationSound>[];
  NotificationSound? looping;
  int stopLoopCalls = 0;

  @override
  Future<void> play(NotificationSound sound) async => played.add(sound);

  @override
  Future<void> loop(NotificationSound sound) async => looping = sound;

  @override
  Future<void> stopLoop() async {
    stopLoopCalls++;
    looping = null;
  }

  @override
  Future<void> dispose() async {}
}

const _me = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Setup {
  _Setup(this.container, this.events, this.player);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _FakePlayer player;

  Future<void> dispose() async {
    container.dispose();
    await events.close();
  }
}

Future<_Setup> _wire({List<Override> extra = const []}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  final player = _FakePlayer();

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _me)),
      liveEventsProvider.overrideWithValue(events.stream),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: player),
      ),
      ...extra,
    ],
  );
  container.read(notificationSoundControllerProvider);
  container.read(voiceSettingsControllerProvider);
  await pumpEventQueue();

  return _Setup(container, events, player);
}

void _ring(_Setup s, {String channelId = 'dm-1', String callerId = 'alice'}) =>
    s.events.add(
      api.CallRinging(
        channelId: channelId,
        ringId: 'ring-1',
        callerId: callerId,
      ),
    );

void _endRing(_Setup s, api.CallOutcome outcome) => s.events.add(
  api.CallRingEnded(channelId: 'dm-1', ringId: 'ring-1', outcome: outcome),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an incoming ring starts the looping ring sound', () async {
    final setup = await _wire();
    _ring(setup);
    await pumpEventQueue();

    expect(setup.player.looping, NotificationSound.callRing);
    await setup.dispose();
  });

  test('answering stops the ring sound', () async {
    final setup = await _wire();
    _ring(setup);
    await pumpEventQueue();
    _endRing(setup, api.CallOutcome.answered);
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    expect(setup.player.stopLoopCalls, 1);
    await setup.dispose();
  });

  test('declining stops the ring sound', () async {
    final setup = await _wire();
    _ring(setup);
    await pumpEventQueue();
    _endRing(setup, api.CallOutcome.declined);
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    await setup.dispose();
  });

  test('the ring timing out stops the ring sound', () async {
    final setup = await _wire();
    _ring(setup);
    await pumpEventQueue();
    _endRing(setup, api.CallOutcome.timedOut);
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    await setup.dispose();
  });

  test('voice activity with no ring behind it plays nothing - the phantom-ring '
      'regression: a DM call becoming active used to chime on its own, with no '
      'overlay and no ring to explain it', () async {
    final setup = await _wire();
    setup.events.add(const api.VoiceActivityChanged(channelId: 'dm-1'));
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });

  test('this device\'s own outgoing ring never rings for itself', () async {
    final setup = await _wire();
    _ring(setup, callerId: 'me');
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    await setup.dispose();
  });

  test('a call this device is already on does not ring', () async {
    late _FixedChannelVoiceController voice;
    final setup = await _wire(
      extra: [
        voiceControllerProvider.overrideWith((ref) {
          voice = _FixedChannelVoiceController(ref);
          return voice;
        }),
      ],
    );
    voice.setChannel('dm-1');
    await pumpEventQueue();

    _ring(setup);
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    await setup.dispose();
  });

  test('turning the incoming-call sound off silences a real ring', () async {
    final setup = await _wire();
    await setup.container
        .read(voiceSettingsControllerProvider.notifier)
        .setCallRingSoundEnabled(false);
    _ring(setup);
    await pumpEventQueue();

    expect(setup.player.looping, isNull);
    await setup.dispose();
  });
}
