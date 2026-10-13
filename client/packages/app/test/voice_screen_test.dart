// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the voice join preview's error handling: a failure this channel
/// cannot retry its way out of must not offer a button that only fails again,
/// and the one call controller's state must never leak across channels.
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
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_app/src/widgets/call_participant_tiles.dart';
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

/// A [VoiceSession] most tests here never actually drive into a call, since
/// they care only about a failed `join`, before any session state matters.
/// [connectedParticipants], when given, is what the camera-preview tests use
/// instead: `join` reports connected with exactly that roster, the same
/// shape a real SFU handshake would report.
class _NoopSession with VideoQualityRecorder implements VoiceSession {
  _NoopSession({this.connectedParticipants});

  final List<VoiceParticipant>? connectedParticipants;

  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  final Map<String, double> _volumes = {};

  @override
  double volumeFor(String identity) => _volumes[identity] ?? 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {
    _volumes[identity] = volume.clamp(0.0, 2.0);
  }

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  @override
  bool deafened = false;

  @override
  VoiceSessionState get state => VoiceSessionState.idle;

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  List<VoiceParticipant> get participants => connectedParticipants ?? const [];

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

  final Set<String> _locallyMuted = {};

  @override
  bool isLocallyMuted(String identity) => _locallyMuted.contains(identity);

  @override
  Future<void> setLocallyMuted(String identity, bool muted) async {
    muted ? _locallyMuted.add(identity) : _locallyMuted.remove(identity);
  }

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
  }) async {
    final roster = connectedParticipants;
    if (roster == null) return;
    _participants.add(roster);
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

http.Client _tokenApi(int status) => MockClient((request) async {
  if (status == 200) {
    return http.Response(
      jsonEncode({
        'url': 'wss://sfu.example.com',
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
    jsonEncode({
      'error': {'code': 'nope', 'message': 'refused'},
    }),
    status,
    headers: {'content-type': 'application/json'},
  );
});

/// Answers a channel's own `voice/token` request with whatever status
/// [statusByChannel] names for it, 200 for any channel left out - what makes
/// a genuine per-channel leak test possible now that arriving at a voice
/// channel joins it automatically rather than waiting on a tap.
http.Client _perChannelTokenApi(Map<String, int> statusByChannel) =>
    MockClient((request) async {
      final match = RegExp(
        r'/channels/([^/]+)/voice/token',
      ).firstMatch(request.url.path);
      final status = statusByChannel[match?.group(1)] ?? 200;
      if (status == 200) {
        return http.Response(
          jsonEncode({
            'url': 'wss://sfu.example.com',
            'room': match?.group(1),
            'token': 'jwt',
            'expires_at': 0,
            'can_publish': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'error': {'code': 'nope', 'message': 'refused'},
        }),
        status,
        headers: {'content-type': 'application/json'},
      );
    });

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

/// A container already connected to `channel-1`, with a single local
/// participant whose camera is [isCameraOn] - the shared setup for both
/// camera-preview tests below.
ProviderContainer _connectedContainer({required bool isCameraOn}) =>
    ProviderContainer(
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
            httpClient: _tokenApi(200),
          );
          ref.onDispose(api.close);
          return api;
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(
            ref,
            session: _NoopSession(
              connectedParticipants: [
                VoiceParticipant(
                  identity: 'user-1',
                  name: 'Me',
                  isSpeaking: false,
                  isMuted: false,
                  isLocal: true,
                  isScreenSharing: false,
                  isCameraOn: isCameraOn,
                ),
              ],
            ),
          ),
        ),
      ],
    );

void main() {
  testWidgets(
    'a server with no voice hides the join button rather than inviting a retry',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          // The preview polls this every 15 seconds now that it shows who
          // is already in the call; without a stub the timer outlives the test.
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
              httpClient: _tokenApi(501),
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

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), container),
      );
      await tester.pumpAndSettle();

      await container.read(voiceControllerProvider.notifier).join('channel-1');
      await tester.pumpAndSettle();

      expect(find.text('This Space has no voice configured.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Join call'), findsNothing);
      // The shared component, not a hand-rolled Text: the surface the report named as reaching raw exceptions full-screen.
      expect(find.byType(AppErrorState), findsOneWidget);
    },
  );

  testWidgets(
    "a permission denial in one channel does not block joining another",
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          // The preview polls this every 15 seconds now that it shows who
          // is already in the call; without a stub the timer outlives the test.
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
              // channel-b is left out, so its own automatic join succeeds.
              httpClient: _perChannelTokenApi({'channel-a': 403}),
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

      await container.read(voiceControllerProvider.notifier).join('channel-a');

      // channel-b arrives fresh: its own automatic join must start clean.
      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-b'), container),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to join this channel.'),
        findsNothing,
        reason: "channel-a's denial must not leak into channel-b's screen",
      );
      expect(find.byType(AppErrorState), findsNothing);
    },
  );

  testWidgets(
    'arriving at another channel while a join is still awaiting its token '
    'shows the switch prompt rather than silently starting a second join',
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
                final match = RegExp(
                  r'/channels/([^/]+)/voice/token',
                ).firstMatch(request.url.path);
                // channel-a's token request never resolves, holding the join in the window this fix covers.
                if (match?.group(1) == 'channel-a') {
                  await tokenGate.future;
                }
                return http.Response(
                  jsonEncode({
                    'url': 'wss://sfu.example.com',
                    'room': match?.group(1),
                    'token': 'jwt',
                    'expires_at': 0,
                    'can_publish': true,
                  }),
                  200,
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

      // Not awaited: left suspended, the same as a real arrival still waiting on its token.
      unawaited(
        container.read(voiceControllerProvider.notifier).join('channel-a'),
      );

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-b'), container),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Already in a call'),
        findsOneWidget,
        reason:
            'a join still awaiting its token is a call already in progress '
            'and must still gate a switch to another channel',
      );

      tokenGate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    "a local camera track renders inside the local participant's own tile, "
    'not a separate preview',
    (tester) async {
      final container = _connectedContainer(isCameraOn: true);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), container),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallParticipantTile), findsOneWidget);
      expect(find.byKey(const Key('fake-camera-view-user-1')), findsOneWidget);

      // Stops the heartbeat timer `connected` started: the pending-timer
      // check runs before `addTearDown`, so this has to happen in the body.
      await container.read(voiceControllerProvider.notifier).leave();
    },
  );

  testWidgets(
    "a local participant with the camera off renders their tile as an "
    'avatar, with no camera view mounted',
    (tester) async {
      final container = _connectedContainer(isCameraOn: false);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), container),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CallParticipantTile), findsOneWidget);
      expect(find.byKey(const Key('fake-camera-view-user-1')), findsNothing);

      await container.read(voiceControllerProvider.notifier).leave();
    },
  );
}
