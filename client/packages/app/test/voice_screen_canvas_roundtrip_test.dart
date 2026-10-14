// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hanging up after a canvas round trip must not rejoin the call.
///
/// Opening the canvas swaps the whole conversation pane (`home_shell.dart`'s
/// stage ternary), which unmounts `VoiceScreen` and destroys the
/// `_autoJoinedFor` guard remembering that this channel was already joined
/// automatically. Closing the canvas remounts it with that memory blank, so
/// the hang-up that follows read as a fresh arrival and auto-joined straight
/// back in, showing "connecting" - reported from real device use on
/// 2026-08-13.
///
/// The first test mounts the screen while the controller is already
/// connected, which is exactly the state a canvas close leaves behind if the
/// user hangs up only after it reopens; the second instead hangs up while
/// the canvas is still open (`VoiceScreen` unmounted throughout), which
/// leaves `voice.channelId` null rather than merely stale on remount and so
/// exercises `VoiceState.justLeftChannelId` rather than `connectedHere`.
/// Neither drives the pane swap itself: that is `home_shell.dart`'s own
/// behaviour and not what this is about.
library;

import 'dart:async';
import 'dart:convert';

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

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _ConnectableSession with VideoQualityRecorder implements VoiceSession {
  var joinCount = 0;

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();
  var _state = VoiceSessionState.idle;

  @override
  VoiceSessionState get state => _state;

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  List<VoiceParticipant> get participants => const [];

  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    joinCount++;
    _state = VoiceSessionState.connected;
    _states.add(_state);
  }

  @override
  Future<void> leave() async {
    _state = VoiceSessionState.idle;
    _states.add(_state);
  }

  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  @override
  double volumeFor(String identity) => 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {}

  @override
  bool deafened = false;

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
  Widget screenShareViewFor(String identity) => const SizedBox.shrink();

  @override
  Widget cameraViewFor(String identity) => const SizedBox.shrink();

  @override
  void setVideoInterest(Set<String>? tileKeys) {}

  @override
  bool get supportsInputGate => false;

  @override
  Stream<InputGateReading> get inputGateReadings => const Stream.empty();

  @override
  void setInputGate({required bool enabled, required double thresholdDb}) {}

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
  Future<bool> setMicrophoneEnabled(bool enabled) async => true;

  @override
  Future<bool> setCameraEnabled(bool enabled) async => true;

  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
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

ProviderContainer _container(_ConnectableSession session) => ProviderContainer(
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
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/voice/token')) {
            return http.Response(
              jsonEncode({
                'url': 'wss://sfu.invalid',
                'room': 'channel-1',
                'token': 'jwt',
                'expires_at': 0,
                'can_publish': true,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      ref.onDispose(api.close);
      return api;
    }),
    voiceControllerProvider.overrideWith(
      (ref) => VoiceController(ref, session: session),
    ),
  ],
);

void main() {
  testWidgets('hanging up after the canvas closes does not rejoin the call', (
    tester,
  ) async {
    final session = _ConnectableSession();
    final container = _container(session);
    addTearDown(container.dispose);

    final controller = container.read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    await tester.pump();
    expect(session.joinCount, 1);

    // Mounting fresh while already connected is what closing the canvas leaves.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
        ),
      ),
    );
    await tester.pump();

    await controller.leave();
    await tester.pump();
    await tester.pump();

    expect(
      session.joinCount,
      1,
      reason:
          'hanging up must not be read as an arrival worth auto-joining, '
          'however this screen was mounted',
    );
    expect(find.text('You left this call.'), findsOneWidget);
  });

  testWidgets(
    'hanging up while the canvas is open, then closing it, does not rejoin',
    (tester) async {
      final session = _ConnectableSession();
      final container = _container(session);
      addTearDown(container.dispose);

      final controller = container.read(voiceControllerProvider.notifier);
      await controller.join('channel-1');
      await tester.pump();
      expect(session.joinCount, 1);

      // The explicit hang-up itself, with no `VoiceScreen` mounted: `_autoJoinedFor` does not exist yet for this remount to inherit.
      await controller.leave();

      // Closing the canvas: a brand new `VoiceScreen` `State`, but now `voice.channelId` is null so `connectedHere` cannot be what saves it.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        session.joinCount,
        1,
        reason:
            'an explicit hang-up made before the canvas even closes must '
            'still land on the left-this-call screen, not a silent rejoin',
      );
      expect(find.text('You left this call.'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
