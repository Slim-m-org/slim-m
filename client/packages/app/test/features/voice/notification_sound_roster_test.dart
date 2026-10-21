// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s voice-roster half: member join/leave
/// chimes, the baseline that keeps a room's existing occupants from reading
/// as a burst of joins, the owner's own "roughly 8 participants" ceiling,
/// and the call-failure error chime.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/features/settings/providers/ui_sound_settings.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/dead_voice_session.dart';
import '../../support/fake_sound_player.dart';

/// A [DeadVoiceSession] the test can push states and participants through.
class _FakeSession extends DeadVoiceSession {
  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  @override
  Stream<VoiceSessionState> get states => _states.stream;
  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;
  @override
  VoiceDisconnect? lastDisconnect;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }

  void emitState(VoiceSessionState next) => _states.add(next);
  void emitParticipants(List<VoiceParticipant> next) => _participants.add(next);
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

VoiceParticipant _participant(String identity, {bool isLocal = false}) =>
    VoiceParticipant(
      identity: identity,
      name: identity,
      isLocal: isLocal,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: false,
    );

class _Setup {
  _Setup(this.container, this.session, this.player);

  final ProviderContainer container;
  final _FakeSession session;
  final RecordingSoundPlayer player;
}

Future<_Setup> _wire() async {
  final session = _FakeSession();
  final player = RecordingSoundPlayer();

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: player),
      ),
    ],
  );
  container.read(notificationSoundControllerProvider);
  // Settles the join/leave and call-ring toggle loads (both default true).
  container.read(voiceSettingsControllerProvider);
  container.read(uiSoundSettingsProvider);
  await pumpEventQueue();

  return _Setup(container, session, player);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This file is about other members' cues, so the self cues are switched off.
  setUp(
    () => SharedPreferences.setMockInitialValues({uiSoundsEnabledKey: false}),
  );

  test('connecting to a room that already has people plays nothing', () async {
    final setup = await _wire();
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      _participant('a'),
    ]);
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
  });

  test('someone joining after connected plays member_join', () async {
    final setup = await _wire();
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([_participant('me', isLocal: true)]);
    await pumpEventQueue();
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      _participant('a'),
    ]);
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.memberJoin]);
  });

  test('someone leaving plays member_leave', () async {
    final setup = await _wire();
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      _participant('a'),
    ]);
    await pumpEventQueue();
    setup.session.emitParticipants([_participant('me', isLocal: true)]);
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.memberLeave]);
  });

  test(
    'leaving and rejoining the same room does not replay old joins',
    () async {
      final setup = await _wire();
      setup.session.emitState(VoiceSessionState.connected);
      setup.session.emitParticipants([
        _participant('me', isLocal: true),
        _participant('a'),
      ]);
      await pumpEventQueue();
      setup.session.emitState(VoiceSessionState.idle);
      await pumpEventQueue();
      setup.session.emitState(VoiceSessionState.connected);
      setup.session.emitParticipants([
        _participant('me', isLocal: true),
        _participant('a'),
      ]);
      await pumpEventQueue();

      expect(setup.player.played, isEmpty);
    },
  );

  test('turning join/leave sounds off silences a real join', () async {
    final setup = await _wire();
    await setup.container
        .read(voiceSettingsControllerProvider.notifier)
        .setJoinLeaveSoundsEnabled(false);
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([_participant('me', isLocal: true)]);
    await pumpEventQueue();
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      _participant('a'),
    ]);
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
  });

  test('a join that brings the room to 9 plays nothing', () async {
    final setup = await _wire();
    final seven = [for (var i = 0; i < 7; i++) _participant('p$i')];
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      ...seven,
    ]);
    await pumpEventQueue();
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      ...seven,
      _participant('nine'),
    ]);
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
  });

  test('a join that keeps the room at 8 still chimes', () async {
    final setup = await _wire();
    final six = [for (var i = 0; i < 6; i++) _participant('p$i')];
    setup.session.emitState(VoiceSessionState.connected);
    setup.session.emitParticipants([_participant('me', isLocal: true), ...six]);
    await pumpEventQueue();
    setup.session.emitParticipants([
      _participant('me', isLocal: true),
      ...six,
      _participant('eight'),
    ]);
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.memberJoin]);
  });

  test(
    'a call that drops and does not recover plays the error chime',
    () async {
      final setup = await _wire();
      setup.session.lastDisconnect = VoiceDisconnect.connectionLost;
      setup.session.emitState(VoiceSessionState.failed);
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.error]);
    },
  );

  test('the same error is not replayed on a repeated frame', () async {
    final setup = await _wire();
    setup.session.lastDisconnect = VoiceDisconnect.connectionLost;
    setup.session.emitState(VoiceSessionState.failed);
    await pumpEventQueue();
    setup.session.emitState(VoiceSessionState.failed);
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.error]);
  });
}
