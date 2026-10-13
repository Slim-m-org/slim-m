// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice screen's stage transitions: a fast join failure was found to
/// hand off through a blank, unlabelled frame before landing on its real
/// error - reproduced here against the widget itself, not inferred from
/// reading the stage computation.
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

class _NoopSession with VideoQualityRecorder implements VoiceSession {
  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  @override
  double volumeFor(String identity) => 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {}

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

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
  }) async => ScreenShareOutcome.started;

  @override
  Future<bool> setDeafened(bool value) async => true;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }
}

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'a join still awaiting its token never shows the left-this-call screen',
    (tester) async {
      final tokenGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          voiceRosterProvider.overrideWith(
            (ref, channelId) =>
                const Stream<List<VoiceRosterParticipant>>.empty(),
          ),
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                // Holds the join between joining being set and state moving off idle.
                await tokenGate.future;
                return http.Response(
                  jsonEncode({
                    'error': {'code': 'not_configured', 'message': 'no sfu'},
                  }),
                  501,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: _NoopSession()),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() {
        if (!tokenGate.isCompleted) tokenGate.complete();
      });

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), container),
      );
      // The post-frame callback calling join runs here, setting joining mid-flight.
      await tester.pump();
      await tester.pump();

      expect(
        find.text('You left this call.'),
        findsNothing,
        reason:
            'a join in flight is not a rejoin screen, however briefly the '
            'stage computation might disagree',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      tokenGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('This Space has no voice configured.'), findsOneWidget);
    },
  );
}
