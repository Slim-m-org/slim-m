// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the two suites that drive a [VoiceController]: the
/// controller's own behaviour, and the iOS broadcast handoff.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. Both
/// suites need the same hand-driven [VoiceSession], the same token endpoint
/// and the same provider wiring around them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_auto_rejoin.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/video_quality_recorder.dart';

const tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A [VoiceSession] the test drives by hand.
///
/// Implemented rather than subclassed so that adding a method to the real
/// session is a compile error here, not a silently untested path.
class FakeSession with VideoQualityRecorder implements VoiceSession {
  FakeSession({
    this.joinOutcome = VoiceSessionState.connected,
    this.microphoneGranted = true,
    this.cameraGranted = true,
    this.cameraFailureReason,
    this.screenShareOutcome = ScreenShareOutcome.started,
    this.deafenGranted = true,
    this.needsSource = false,
    this.sources = const [],
    this.sourcePickerUseful = true,
    this.canFlipCamera = false,
    this.cameraNeedsSelection = false,
    this.cameraDeviceList = const [],
    this.supportsScreenShareAudio = true,
    this.supportsAudioInputSelection = true,
    this.supportsAudioOutputSelection = true,
    this.audioInputDeviceList = const [],
    this.audioOutputDeviceList = const [],
  });

  @override
  bool get supportsParticipantVolume => true;

  @override
  final bool supportsScreenShareAudio;

  @override
  final bool supportsAudioInputSelection;

  @override
  final bool supportsAudioOutputSelection;

  /// What [audioInputDevices] answers with.
  final List<AudioDevice> audioInputDeviceList;

  /// What [audioOutputDevices] answers with.
  final List<AudioDevice> audioOutputDeviceList;

  final _audioDeviceChanges = StreamController<void>.broadcast();

  @override
  Stream<void> get audioDeviceChanges => _audioDeviceChanges.stream;

  @override
  Future<List<AudioDevice>> audioInputDevices() async => audioInputDeviceList;

  @override
  Future<List<AudioDevice>> audioOutputDevices() async => audioOutputDeviceList;

  /// What the controller actually passed through, so a test can assert the
  /// chosen device reached the session.
  AudioDevice? lastSelectedAudioInput;
  AudioDevice? lastSelectedAudioOutput;

  @override
  Future<bool> selectAudioInputDevice(AudioDevice? device) async {
    lastSelectedAudioInput = device;
    return true;
  }

  @override
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async {
    lastSelectedAudioOutput = device;
    return true;
  }

  /// Every `includeAudio` a call to [setScreenShareEnabled] received, in
  /// order.
  final List<bool> screenShareAudioCalls = [];

  final Map<String, double> _volumes = {};

  @override
  double volumeFor(String identity) => _volumes[identity] ?? 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {
    _volumes[identity] = volume.clamp(0.0, 2.0);
  }

  final VoiceSessionState joinOutcome;
  final bool microphoneGranted;
  final bool cameraGranted;

  /// What a refused [setCameraEnabled] classifies as, the way
  /// `CameraSwitching.setEnabled` would; `null` drives the plain, unclassified
  /// path a real refusal `classifyCameraFailure` could not read anything out
  /// of also takes.
  final CameraFailureReason? cameraFailureReason;

  /// What a request to start sharing reports back. Every branch the
  /// controller has to tell apart is one of these.
  final ScreenShareOutcome screenShareOutcome;
  final bool deafenGranted;

  /// Whether this platform makes a share name a screen first.
  final bool needsSource;
  final List<ScreenShareSource> sources;

  /// Whether several enumerated sources are worth their own picker; see
  /// [DesktopSources.sourcePickerUseful].
  final bool sourcePickerUseful;

  @override
  final bool canFlipCamera;

  @override
  final bool cameraNeedsSelection;

  /// What [cameraDevices] answers with.
  final List<CameraDevice> cameraDeviceList;

  /// What the controller actually passed through, so a test can assert the
  /// chosen camera reached the session.
  CameraDevice? lastSelectedCamera;
  int flipCameraCalls = 0;
  bool? askedForCameraOnToggle;

  /// What the controller actually passed through, so a test can assert the
  /// chosen screen reached the session rather than being dropped.
  String? lastSourceId;
  int sourceListings = 0;

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  VoiceSessionState _state = VoiceSessionState.idle;
  bool? askedForMicrophoneOnJoin;
  bool? askedForCameraOnJoin;
  int leaveCalls = 0;

  /// Holds [leave] open until a test completes it, so a teardown that is
  /// genuinely still unwinding can be raced against a fresh [join] the way a
  /// real `room.disconnect()` round trip lets a person race it by hand.
  Completer<void>? leaveGate;

  /// Holds [setMicrophoneEnabled] open the same way, so a mute whose SFU round
  /// trip is still in flight can be raced against a hang-up and a fresh join.
  Completer<void>? microphoneGate;

  /// The real session's own supersession counter, modelled here so a gated
  /// [leave] behaves the way the thing it stands in for does.
  int _generation = 0;

  @override
  bool deafened = false;

  @override
  VoiceSessionState get state => _state;

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  List<VoiceParticipant> get participants => const [];

  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;

  Object? _lastError;

  @override
  Object? get lastError =>
      _lastError ??
      (_state == VoiceSessionState.failed ? 'the SFU refused' : null);

  @override
  VoiceDisconnect? lastDisconnect;

  @override
  bool get screenShareNeedsSource => needsSource;

  @override
  bool get screenShareSourcePickerUseful => sourcePickerUseful;

  @override
  Future<List<ScreenShareSource>> screenShareSources() async {
    sourceListings++;
    return sources;
  }

  /// Keyed so a widget test can assert the share surface mounted for the
  /// right participant without a real room behind it.
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

  /// Every interest set this session has been handed, newest last, so a test
  /// can assert on the resulting set rather than only that a call happened.
  final List<Set<String>?> videoInterests = [];

  @override
  void setVideoInterest(Set<String>? tileKeys) => videoInterests.add(tileKeys);

  /// The last sensitivity this session was handed, so a test can assert it
  /// reached the session rather than only the controller's own copy.
  double? lastSpeakingSensitivity;

  @override
  bool get supportsInputGate => false;

  @override
  Stream<InputGateReading> get inputGateReadings => const Stream.empty();

  @override
  void setInputGate({required bool enabled, required double thresholdDb}) {}

  @override
  void setSpeakingSensitivity(double sensitivity) =>
      lastSpeakingSensitivity = sensitivity;

  @override
  Future<List<CameraDevice>> cameraDevices() async => cameraDeviceList;

  @override
  Future<bool> flipCamera() async {
    flipCameraCalls++;
    return cameraGranted;
  }

  @override
  Future<bool> selectCameraDevice(CameraDevice device) async {
    lastSelectedCamera = device;
    return cameraGranted;
  }

  /// Drives a drop the SFU decided on, the way a real room event would.
  void dropWith(VoiceDisconnect reason) {
    lastDisconnect = reason;
    _state = VoiceSessionState.failed;
    _states.add(_state);
  }

  /// Pushes any other session-state transition through the same stream
  /// `join`'s own outcome never emits on, since nothing here drives a real
  /// `Room`'s events.
  void emitState(VoiceSessionState next) {
    _state = next;
    _states.add(next);
  }

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    askedForMicrophoneOnJoin = microphoneEnabled;
    askedForCameraOnJoin = cameraEnabled;
    _generation++;
    _state = joinOutcome;
  }

  @override
  Future<void> leave() async {
    leaveCalls++;
    final generation = ++_generation;
    await leaveGate?.future;
    // Mirrors the real `VoiceSession.leave`'s own supersession guard.
    if (generation != _generation) return;
    _state = VoiceSessionState.idle;
    // The real session emits this transition too, and a fake that did not was untested here.
    _states.add(_state);
  }

  @override
  Future<bool> setMicrophoneEnabled(bool enabled) async {
    final gate = microphoneGate;
    if (gate != null) await gate.future;
    return microphoneGranted;
  }

  /// Records a cause on refusal, `setScreenShareEnabled`'s own reasoning
  /// below: a fake that drops it cannot catch a controller that does too.
  @override
  Future<bool> setCameraEnabled(bool enabled) async {
    askedForCameraOnToggle = enabled;
    if (!cameraGranted) {
      final reason = cameraFailureReason;
      _lastError = reason == null
          ? 'no camera device found'
          : CameraFailure('no camera device found', reason);
    }
    return cameraGranted;
  }

  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async {
    lastSourceId = sourceId;
    screenShareAudioCalls.add(includeAudio);
    if (!enabled) return ScreenShareOutcome.stopped;
    // The real session records why before reporting failure; a fake that does
    // not cannot catch a controller that drops the cause.
    if (screenShareOutcome == ScreenShareOutcome.failed) {
      _lastError = 'source not found!';
    }
    return screenShareOutcome;
  }

  @override
  Future<bool> setDeafened(bool value) async {
    if (!deafenGranted) return false;
    deafened = value;
    return true;
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
    await _audioDeviceChanges.close();
  }

  void emitParticipants(List<VoiceParticipant> p) => _participants.add(p);
}

/// Answers the token and heartbeat endpoints however the test asks.
///
/// [sfuUrl] defaults to a wss address, the only shape the server's own
/// config validation and most tests need; the plain-ws suite overrides it.
/// [onRequest], when given, is called with every request this client
/// answers, so a test can count or inspect heartbeat calls without a second
/// mock layered on top. The whole request, not just the url: a POST
/// heartbeat and the DELETE that forgets one on a clean leave share a path,
/// and only the method tells them apart.
/// [failHeartbeat] models a heartbeat that cannot reach the server while the
/// media transport stays up entirely, the case
/// `voice_call_heartbeat_test.dart`'s lag tests need: a POST failure with no
/// change to how `/voice/token` answers.
http.Client voiceApi({
  int status = 200,
  bool canPublish = true,
  String sfuUrl = 'wss://sfu.example.com',
  bool failHeartbeat = false,
  int? callAgeMs,
  void Function(http.Request request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    if (request.url.path.endsWith('/voice/heartbeat')) {
      if (failHeartbeat && request.method == 'POST') {
        return http.Response('', 503);
      }
      return http.Response('', 204);
    }
    if (request.url.path.endsWith('/voice/roster')) {
      return http.Response('{"participants":[],"call_age_ms":$callAgeMs}', 200);
    }
    if (!request.url.path.endsWith('/voice/token')) {
      return http.Response('{}', 404);
    }
    if (status != 200) {
      return http.Response(
        jsonEncode({
          'error': {'code': 'nope', 'message': 'refused'},
        }),
        status,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({
        'url': sfuUrl,
        'room': 'channel-1',
        'token': 'jwt',
        'expires_at': 0,
        'can_publish': canPublish,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// A [VoiceController] pinned to [fixed], for a test that renders against a
/// known [VoiceState] without driving a real join through it. `state` is
/// only settable from within a [VoiceController] subclass, never from
/// outside one, which is why this exists rather than a plain field assign.
class FixedVoiceController extends VoiceController {
  FixedVoiceController(super.ref, VoiceState fixed)
    : super(session: FakeSession()) {
    state = fixed;
  }
}

/// Owns the container so a suite can tear it down in one place.
class VoiceHarness {
  ProviderContainer? _container;

  /// For a widget test to wrap in `UncontrolledProviderScope`; only valid
  /// after [controllerWith] has built one.
  ProviderContainer get container => _container!;

  void dispose() => _container?.dispose();

  /// What the controller recorded for the user to read back in settings.
  List<DiagnosticEvent> log(VoiceController _) =>
      _container!.read(debugLogProvider);

  /// The controller as the app builds it, with only the network and the SFU
  /// swapped: a real session, a real [SlimmApi], and the same provider wiring.
  ///
  /// [now], when given, stands in for `DateTime.now()` everywhere the
  /// controller reads the clock - the call recap's duration math, so a test
  /// can advance it by hand rather than racing real wall time.
  /// [extraOverrides] append onto the fixed list above, for a caller (a
  /// widget test) that also needs to stub something like `voiceRosterProvider`.
  VoiceController controllerWith(
    FakeSession session,
    http.Client client, {
    Duration broadcastStartTimeout = const Duration(seconds: 30),
    Duration voiceHeartbeatInterval = const Duration(seconds: 15),
    List<Duration> autoRejoinDelays = VoiceAutoRejoin.defaultDelays,
    CallLifecycleChannel? callLifecycle,
    DateTime Function()? now,
    List<Override> extraOverrides = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(api.close);
          return api;
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(
            ref,
            session: session,
            broadcastStartTimeout: broadcastStartTimeout,
            voiceHeartbeatInterval: voiceHeartbeatInterval,
            autoRejoinDelays: autoRejoinDelays,
            callLifecycle: callLifecycle,
            now: now,
          ),
        ),
        ...extraOverrides,
      ],
    );
    _container = container;
    return container.read(voiceControllerProvider.notifier);
  }
}
