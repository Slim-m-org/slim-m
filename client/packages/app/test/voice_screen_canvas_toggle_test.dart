// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call dock's own canvas toggle, driven through the real
/// [VoiceScreen] state machine rather than [VoiceCallDock] directly - so
/// this is the one suite proving [VoiceScreen]'s `isDm` flag actually reaches
/// the dock's own gate, not only that the dock honours whatever it is told.
///
/// Split out of `voice_screen_test.dart`, which was already at this repo's
/// file budget before this task added anything to it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/video_quality_recorder.dart';

/// A [VoiceSession] whose `join` resolves straight to a connected call with
/// one local participant, the shortest path to the dock this suite needs -
/// `voice_screen_test.dart`'s own `_NoopSession` does the identical thing for
/// its own camera-preview tests.
class _ConnectedSession with VideoQualityRecorder implements VoiceSession {
  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  @override
  void setSpeakingSensitivity(double sensitivity) {}

  @override
  double volumeFor(String identity) => 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {}

  @override
  bool deafened = false;

  @override
  VoiceSessionState get state => VoiceSessionState.idle;

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  List<VoiceParticipant> get participants => const [];

  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;

  @override
  Object? get lastError => null;

  @override
  VoiceDisconnect? get lastDisconnect => null;

  @override
  bool get screenShareNeedsSource => false;

  @override
  bool get screenShareSourcePickerUseful => true;

  @override
  Future<List<ScreenShareSource>> screenShareSources() async => const [];

  @override
  bool isLocallyMuted(String identity) => false;

  @override
  Future<void> setLocallyMuted(String identity, bool muted) async {}

  @override
  Widget screenShareViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-share-view-$identity'));

  @override
  Widget cameraViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-camera-view-$identity'));

  @override
  void setVideoInterest(Set<String>? tileKeys) {}

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
  }) async {
    _participants.add([
      const VoiceParticipant(
        identity: 'user-1',
        name: 'Me',
        isSpeaking: false,
        isMuted: false,
        isLocal: true,
        isScreenSharing: false,
        isCameraOn: false,
      ),
    ]);
    _states.add(VoiceSessionState.connected);
  }

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
  }) async => ScreenShareOutcome.started;

  @override
  Future<bool> setDeafened(bool value) async => true;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }
}

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _connectedContainer() => ProviderContainer(
  overrides: [
    voiceRosterProvider.overrideWith(
      (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
    ),
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final api = SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient(
          (request) async => http.Response(
            '{"url":"wss://sfu.example.com","room":"channel-1","token":"jwt",'
            '"expires_at":0,"can_publish":true}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      ref.onDispose(api.close);
      return api;
    }),
    voiceControllerProvider.overrideWith(
      (ref) => VoiceController(ref, session: _ConnectedSession()),
    ),
  ],
);

void main() {
  testWidgets(
    "a real voice channel's in-call dock offers a one-tap way into its own "
    'canvas',
    (tester) async {
      final container = _connectedContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);

      // Stops the heartbeat timer `connected` started, before the pending-timer check that runs ahead of `addTearDown`.
      await container.read(voiceControllerProvider.notifier).leave();
    },
  );

  testWidgets(
    "a DM's call offers no canvas toggle at all - canvas is not a DM's to "
    'open, the same self-gating the channel header already carries',
    (tester) async {
      final container = _connectedContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(
              body: VoiceScreen(channelId: 'channel-1', isDm: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Open canvas'), findsNothing);

      await container.read(voiceControllerProvider.notifier).leave();
    },
  );
}
