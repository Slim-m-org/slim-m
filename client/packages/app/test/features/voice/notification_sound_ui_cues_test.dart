// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s interface cues: this device's own call
/// join, leave, mute and deafen, the ringback while its own DM call rings,
/// and the send cue, each playing once and obeying its settings.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/features/settings/providers/ui_sound_settings.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/dead_voice_session.dart';

class _Voice extends VoiceController {
  _Voice(super.ref) : super(session: DeadVoiceSession());

  void update(VoiceState Function(VoiceState) change) => state = change(state);
}

class _Ring extends DmCallRingController {
  _Ring(super.ref);

  void setOutgoing(OutgoingDmCallRing? ring) =>
      state = state.copyWith(outgoing: ring, clearOutgoing: ring == null);
}

class _Player implements SoundPlayer {
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

const _outgoing = OutgoingDmCallRing(channelId: 'dm-1', ringId: 'ring-1');

class _Setup {
  _Setup(this.container, this.player, this.cues);

  final ProviderContainer container;
  final _Player player;
  final List<String> cues;

  _Voice get voice =>
      container.read(voiceControllerProvider.notifier) as _Voice;
  _Ring get ring =>
      container.read(dmCallRingControllerProvider.notifier) as _Ring;

  Future<void> connect() async {
    voice.update((s) => s.copyWith(state: VoiceSessionState.connected));
    await pumpEventQueue();
    player.played.clear();
    cues.clear();
  }

  Future<void> change(VoiceState Function(VoiceState) change) async {
    voice.update(change);
    await pumpEventQueue();
  }
}

Future<_Setup> _wire(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final player = _Player();
  final cues = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      voiceControllerProvider.overrideWith(_Voice.new),
      dmCallRingControllerProvider.overrideWith(_Ring.new),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(
          ref,
          player: player,
          toggleHaptic: () => cues.add('toggle'),
        ),
      ),
    ],
  );
  container.read(notificationSoundControllerProvider);
  container.read(voiceSettingsControllerProvider);
  container.read(uiSoundSettingsProvider);
  await pumpEventQueue();
  return _Setup(container, player, cues);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('joining and leaving your own call play one cue each', () async {
    final s = await _wire({});
    await s.change((v) => v.copyWith(state: VoiceSessionState.connected));
    expect(s.player.played, [NotificationSound.selfJoin]);
    await s.change((v) => v.copyWith(state: VoiceSessionState.idle));
    expect(s.player.played, [
      NotificationSound.selfJoin,
      NotificationSound.selfLeave,
    ]);
    s.container.dispose();
  });

  test('a rejoin after a drop plays no join cue', () async {
    final s = await _wire({});
    await s.change((v) => v.copyWith(rejoining: true));
    await s.change((v) => v.copyWith(state: VoiceSessionState.connected));
    expect(s.player.played, isEmpty);
    s.container.dispose();
  });

  test('muting and unmuting play mute on and off once each', () async {
    final s = await _wire({});
    await s.connect();
    await s.change((v) => v.copyWith(microphoneEnabled: false));
    await s.change((v) => v.copyWith(microphoneEnabled: true));
    expect(s.player.played, [
      NotificationSound.muteOn,
      NotificationSound.muteOff,
    ]);
    expect(s.cues, ['toggle', 'toggle']);
    s.container.dispose();
  });

  test('deafening plays the deafen cue and not the mute cue', () async {
    final s = await _wire({});
    await s.connect();
    await s.change((v) => v.copyWith(deafened: true, microphoneEnabled: false));
    await s.change((v) => v.copyWith(deafened: false, microphoneEnabled: true));
    expect(s.player.played, [
      NotificationSound.deafenOn,
      NotificationSound.deafenOff,
    ]);
    s.container.dispose();
  });

  test('holding push-to-talk is not a mute toggle', () async {
    final s = await _wire({'slimm.voice.push_to_talk_enabled': true});
    await s.connect();
    await s.change((v) => v.copyWith(microphoneEnabled: false));
    expect(s.player.played, isEmpty);
    expect(s.cues, isEmpty);
    s.container.dispose();
  });

  test(
    'interface sounds off silences every own-call cue but not haptics',
    () async {
      final s = await _wire({uiSoundsEnabledKey: false});
      await s.change((v) => v.copyWith(state: VoiceSessionState.connected));
      await s.change((v) => v.copyWith(microphoneEnabled: false));
      s.ring.setOutgoing(_outgoing);
      await pumpEventQueue();
      expect(s.player.played, isEmpty);
      expect(s.player.looping, isNull);
      expect(s.cues, ['toggle']);
      s.container.dispose();
    },
  );

  test('haptics off silences the toggle tick but not its sound', () async {
    final s = await _wire({hapticsEnabledKey: false});
    await s.connect();
    await s.change((v) => v.copyWith(microphoneEnabled: false));
    expect(s.player.played, [NotificationSound.muteOn]);
    expect(s.cues, isEmpty);
    s.container.dispose();
  });

  group('ringback', () {
    test('loops while an outgoing ring is pending', () async {
      final s = await _wire({});
      s.ring.setOutgoing(_outgoing);
      await pumpEventQueue();
      expect(s.player.looping, NotificationSound.ringback);
      s.container.dispose();
    });

    test('stops when the ring ends: answered, declined or timed out', () async {
      final s = await _wire({});
      s.ring.setOutgoing(_outgoing);
      await pumpEventQueue();
      s.ring.setOutgoing(null);
      await pumpEventQueue();
      expect(s.player.looping, isNull);
      expect(s.player.stopLoopCalls, 1);
      s.container.dispose();
    });

    test('stops when you leave the call while it rings', () async {
      final s = await _wire({});
      await s.connect();
      s.ring.setOutgoing(_outgoing);
      await pumpEventQueue();
      await s.change((v) => v.copyWith(state: VoiceSessionState.idle));
      expect(s.player.looping, isNull);
      expect(s.player.stopLoopCalls, 1);
      s.container.dispose();
    });

    test('stops when the callee joins the call', () async {
      final s = await _wire({});
      await s.connect();
      s.ring.setOutgoing(_outgoing);
      await pumpEventQueue();
      await s.change((v) => v.copyWith(participants: []));
      await s.change(
        (v) => v.copyWith(
          participants: [
            const VoiceParticipant(
              identity: 'alice',
              name: 'alice',
              isSpeaking: false,
              isMuted: false,
              isLocal: false,
              isScreenSharing: false,
            ),
          ],
        ),
      );
      expect(s.player.looping, isNull);
      s.container.dispose();
    });

    test(
      'does not touch the incoming ring loop when nothing rang out',
      () async {
        final s = await _wire({});
        await s.connect();
        await s.change((v) => v.copyWith(state: VoiceSessionState.idle));
        expect(s.player.stopLoopCalls, 0);
        s.container.dispose();
      },
    );
  });

  test(
    'a posted message plays the send cue once, and respects the toggle',
    () async {
      final on = await _wire({});
      on.container.read(messageSentSignalProvider.notifier).state++;
      await pumpEventQueue();
      expect(on.player.played, [NotificationSound.messageSent]);
      on.container.dispose();

      final off = await _wire({uiSoundsEnabledKey: false});
      off.container.read(messageSentSignalProvider.notifier).state++;
      await pumpEventQueue();
      expect(off.player.played, isEmpty);
      off.container.dispose();
    },
  );
}
