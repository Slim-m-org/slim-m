// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s voice-roster half: member join/leave
/// chimes, the baseline that keeps a room's existing occupants from reading
/// as a burst of joins, the owner's own "roughly 8 participants" ceiling,
/// and the call-failure error chime.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/video_quality_recorder.dart';

/// The minimum [VoiceSession] surface the controller needs, the same shape
/// `voice_settings_screen_test.dart`'s own fake already establishes.
class _FakeSession with VideoQualityRecorder implements VoiceSession {
  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  @override
  Stream<VoiceSessionState> get states => _states.stream;
  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;
  @override
  List<VoiceParticipant> get participants => const [];
  @override
  VoiceSessionState get state => VoiceSessionState.idle;
  @override
  Object? get lastError => null;
  @override
  VoiceDisconnect? lastDisconnect;
  @override
  bool deafened = false;
  @override
  bool get supportsParticipantVolume => false;
  @override
  bool get supportsScreenShareAudio => false;
  @override
  double volumeFor(String identity) => 1.0;
  @override
  Future<void> setVolumeFor(String identity, double volume) async {}
  @override
  bool get screenShareNeedsSource => false;
  @override
  bool get screenShareSourcePickerUseful => false;
  @override
  Future<List<ScreenShareSource>> screenShareSources() async => const [];
  @override
  bool isLocallyMuted(String identity) => false;
  @override
  Future<void> setLocallyMuted(String identity, bool muted) async {}
  @override
  Widget screenShareViewFor(String identity) => throw UnimplementedError();
  @override
  Widget cameraViewFor(String identity) => throw UnimplementedError();
  @override
  void setVideoInterest(Set<String>? tileKeys) {}
  @override
  void setSpeakingSensitivity(double sensitivity) {}
  @override
  bool get canFlipCamera => false;
  @override
  bool get cameraNeedsSelection => false;
  @override
  Future<List<CameraDevice>> cameraDevices() async => const [];
  @override
  Future<bool> flipCamera() async => false;
  @override
  Future<bool> selectCameraDevice(CameraDevice device) async => false;

  @override
  bool get supportsAudioInputSelection => false;

  @override
  bool get supportsAudioOutputSelection => false;

  @override
  Stream<void> get audioDeviceChanges => const Stream.empty();

  @override
  Future<List<AudioDevice>> audioInputDevices() async => const [];

  @override
  Future<List<AudioDevice>> audioOutputDevices() async => const [];

  @override
  Future<bool> selectAudioInputDevice(AudioDevice? device) async => false;

  @override
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async => false;
  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {}
  @override
  Future<void> leave() async {}
  @override
  Future<bool> setMicrophoneEnabled(bool enabled) async => true;
  @override
  Future<bool> setCameraEnabled(bool enabled) async => true;
  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.balanced,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async => ScreenShareOutcome.stopped;
  @override
  Future<bool> setDeafened(bool value) async => true;
  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }

  void emitState(VoiceSessionState next) => _states.add(next);
  void emitParticipants(List<VoiceParticipant> next) => _participants.add(next);
}

class _FakePlayer implements SoundPlayer {
  final played = <NotificationSound>[];

  @override
  Future<void> play(NotificationSound sound) async => played.add(sound);

  @override
  Future<void> loop(NotificationSound sound) async {}

  @override
  Future<void> stopLoop() async {}

  @override
  Future<void> dispose() async {}
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
  final _FakePlayer player;
}

Future<_Setup> _wire() async {
  final session = _FakeSession();
  final player = _FakePlayer();

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
  await pumpEventQueue();

  return _Setup(container, session, player);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
