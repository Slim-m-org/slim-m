// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hand-driven [VoiceSession] shared by the voice controller suites.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/video_quality_recorder.dart';

/// A [VoiceSession] the test drives by hand.
///
/// Implemented rather than subclassed so that adding a method to the real
/// session is a compile error here, not a silently untested path.
class FakeSession with VideoQualityRecorder implements VoiceSession {
  /// Every value the controller passed to [setLevelDisplayed].
  final levelDisplayedCalls = <bool>[];

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
  double screenVolumeFor(String identity) => _screenVolumes[identity] ?? 1.0;

  @override
  Future<void> setScreenVolumeFor(String identity, double volume) async {
    _screenVolumes[identity] = volume.clamp(0.0, 2.0);
    volumePushes.add((identity, true, volume));
  }

  final Map<String, double> _screenVolumes = {};

  /// Every gain push, as (identity, screen channel, value), in order.
  final List<(String, bool, double)> volumePushes = [];

  @override
  bool isScreenAudioMuted(String identity) => false;

  @override
  Future<void> setScreenAudioMuted(String identity, bool muted) async {}

  @override
  bool hasScreenAudio(String identity) => false;

  @override
  Object? volumeFailureFor(String identity, {bool screen = false}) => null;

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

  /// Every start or stop the session was asked for, in order.
  final shareCalls =
      <
        ({
          bool enabled,
          ScreenShareQuality quality,
          String? sourceId,
          bool includeAudio,
        })
      >[];

  /// Every camera on or off the session was asked for, in order.
  final cameraToggles = <bool>[];

  /// Every `includeAudio` a call to [setScreenShareEnabled] received, in
  /// order.
  final List<bool> screenShareAudioCalls = [];

  final Map<String, double> _volumes = {};

  @override
  double volumeFor(String identity) => _volumes[identity] ?? 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {
    _volumes[identity] = volume.clamp(0.0, 2.0);
    volumePushes.add((identity, false, volume));
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
  ScreenShareOutcome screenShareOutcome;
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
  bool? joinedAbleToPublish;
  bool? askedForCameraOnJoin;
  int leaveCalls = 0;

  /// Holds [leave] open until a test completes it, so a teardown that is
  /// genuinely still unwinding can be raced against a fresh [join] the way a
  /// real `room.disconnect()` round trip lets a person race it by hand.
  Completer<void>? leaveGate;

  /// Holds [setMicrophoneEnabled] open the same way, so a mute whose SFU round
  /// trip is still in flight can be raced against a hang-up and a fresh join.
  Completer<void>? microphoneGate;

  /// Holds [setCameraEnabled] open, so a camera restart can be raced against a hang-up.
  Completer<void>? cameraGate;

  /// Holds a share stop open, so a quality restart can be raced against a hang-up.
  Completer<void>? shareStopGate;

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

  final sourceLost = StreamController<String>.broadcast();

  @override
  Stream<String> get screenShareSourceLost => sourceLost.stream;

  final enlargedHolds = <String>[];
  final enlargedReleases = <String>[];

  @override
  VoidCallback holdEnlargedVideo(String tileKey) {
    enlargedHolds.add(tileKey);
    return () => enlargedReleases.add(tileKey);
  }

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
  final List<Set<String>> videoBlocked = [];

  @override
  void setVideoInterest(Set<String>? tileKeys) => videoInterests.add(tileKeys);

  @override
  void setVideoBlocked(Set<String> tileKeys) => videoBlocked.add(tileKeys);

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
  Stream<double> get autoInputThresholds => const Stream.empty();

  @override
  double get inputThresholdDb => -50;

  @override
  void setLevelDisplayed(bool displayed) {
    levelDisplayedCalls.add(displayed);
  }

  @override
  void setAutoInputThreshold(bool enabled) {}

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
    bool canPublish = true,
  }) async {
    askedForMicrophoneOnJoin = microphoneEnabled;
    joinedAbleToPublish = canPublish;
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
    cameraToggles.add(enabled);
    final gate = cameraGate;
    if (gate != null) await gate.future;
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
    shareCalls.add((
      enabled: enabled,
      quality: quality,
      sourceId: sourceId,
      includeAudio: includeAudio,
    ));
    screenShareAudioCalls.add(includeAudio);
    if (!enabled) {
      final gate = shareStopGate;
      if (gate != null) await gate.future;
      return ScreenShareOutcome.stopped;
    }
    // The real session records the cause first; a fake that skips it hides a dropped cause.
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
