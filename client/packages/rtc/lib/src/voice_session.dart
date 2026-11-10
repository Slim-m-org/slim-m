// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live voice call, wrapped so nothing outside this package touches LiveKit.
///
/// The rest of the client never imports `livekit_client`. That is not tidiness:
/// a `Room` cannot be constructed in a widget test without a signalling server,
/// so anything that reaches for one directly becomes untestable, and the whole
/// voice surface would then only be exercisable by hand against a real SFU.
/// Everything here goes through [RoomFactory], so a test drives a session with
/// a fake and asserts on real behaviour.
///
/// The types this exposes are ours ([VoiceParticipant], [VoiceSessionState]),
/// so a LiveKit upgrade that renames one of its own is contained here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart'
    show AppLog, LogLevel, LogTag, reportFailure, ignoreError;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
import 'audio_event_scope.dart';
import 'audio_gain.dart' as rtc_gain;
import 'audio_glitch_watch.dart';
import 'broadcast_bridge.dart';
import 'call_diagnostics.dart';
import 'call_stats_sampler.dart';
import 'camera_devices.dart';
import 'camera_join.dart';
import 'camera_switching.dart';
import 'desktop_sources.dart';
import 'input_gate.dart';
import 'join_timings.dart';
import 'livekit_setup_log.dart';
import 'mic_failure.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';
import 'mic_release.dart';
import 'pulse_audio.dart';
import 'screen_share.dart';
import 'screen_share_audio.dart' as rtc_share_audio;
import 'screen_share_local.dart';
import 'share_audio_isolation.dart';
import 'start_bitrate_room.dart';
import 'video_quality.dart';
import 'video_stall_watchdog.dart';
import 'video_subscription_culler.dart';
import 'voice_disconnect_reason.dart';
import 'voice_health.dart';
import 'voice_log.dart';
import 'voice_processing.dart';
import 'voice_processing_control.dart';
import 'voice_models.dart';
import 'voice_roster_snapshot.dart';
import 'voice_input_gate.dart';
import 'voice_listener_audio.dart';
import 'voice_mic_recovery.dart';
import 'voice_mic_readiness.dart';
import 'voice_audio_devices.dart';
import 'voice_health_watch.dart';
import 'voice_session_camera.dart';
import 'voice_roster.dart';
import 'voice_stall_wiring.dart';
import 'voice_stats_wiring.dart';
import 'voice_video_receive.dart';
import 'voice_reconnect_tracker.dart';
import 'voice_session_screen_share.dart';

part 'voice_session_join.dart';
part 'voice_session_tracks.dart';

/// Builds the LiveKit room a session drives. The injection seam.
typedef RoomFactory = lk.Room Function();

/// A voice call in one channel.
///
/// Not a singleton and not global: one session is one call, and the caller owns
/// its lifetime. [dispose] must be called, and leaving is not the same as
/// disposing, because a user can leave and rejoin without the surrounding
/// screen being torn down.
class VoiceSession {
  VoiceSession({
    RoomFactory? roomFactory,
    BroadcastBridge? broadcast,
    DesktopSources? desktopSources,
    CameraDevices? cameraDevices,
    InputGateMonitor? inputGate,
    MicPort? micPort,
    VoiceLog? audioLog,
    AudioDevices? audioDevices,
    LiveOutputSwitch? liveOutput,
    LiveInputSwitch? liveInput,
    PulseAudio? pulse,
    OsMicBlockProbe? osMicBlocked,
    MicRecoveryTiming micRecoveryTiming = const MicRecoveryTiming(),
    Duration micReleaseGrace = kMicReleaseGrace,
    bool? mobile,
    JoinTimings? joinTimings,
    ShareAudioIsolation? shareAudioIsolation,
    Duration cameraJoinTimeout = kJoinCameraTimeout,
  }) : _joinTimings = joinTimings ?? JoinTimings() {
    _roomFactory = roomFactory ?? _buildRoom;
    _listener.audio.log = audioLog;
    // An injected room has no native capture behind it to gate.
    final gate = inputGate ??
        (roomFactory == null
            ? InputGateMonitor()
            : InputGateMonitor.disabled());
    gate.setRate(InputGateRate.watch);
    _mic = micPort ?? LiveKitMicPort(() => _room);
    _audioDevices = VoiceAudioDevices(
      VoiceAudioDevicesHost(
        room: () => _room,
        noteError: (error) => _lastError = error,
        supportsInputGate: () => _inputGate.supported,
        applyInputGate: () => _inputGate.apply(),
        diag: _diag,
      ),
      _mic,
      devices: audioDevices,
      liveOutput: liveOutput,
      liveInput: liveInput,
      pulse: pulse,
    );
    _inputGate = VoiceInputGate(
      VoiceInputGateHost(
        refresh: _refreshParticipants,
        diag: _diag,
        reopenCapture: _reopenCapture,
      ),
      gate: gate,
      mic: _mic,
      switching: _audioSwitching,
    );
    _audioSwitching.levelsNatively = () => _inputGate.levelsNatively;
    _readiness = VoiceMicReadiness(
      VoiceMicReadinessHost(
        hasRoom: () => _room != null,
        mic: _mic,
        micWanted: () => _micRecovery.micWanted,
        plainOptions: _plainOpenOptions,
        joinTimings: _joinTimings,
        diag: _diag,
      ),
      grace: micReleaseGrace,
      mobile: mobile ?? lk.lkPlatformIsMobile(),
    );
    _micRecovery = VoiceMicRecovery(
      VoiceMicRecoveryHost(
        room: () => _room,
        state: () => _state,
        noteError: (error) => _lastError = error,
        refresh: _refreshParticipants,
        diag: _diag,
        openCaptureOptions: _openCaptureOptions,
        forgetUnplugged: _audioDevices.forgetUnplugged,
        followPreferred: _audioDevices.followPreferred,
        selectInput: (device) =>
            _audioDevices.selectInput(device, remember: false),
        selectOutput: (device) =>
            _audioDevices.selectOutput(device, remember: false),
        micPublished: () => _joinTimings.mark(JoinStage.micPublished),
      ),
      mic: _mic,
      gate: gate,
      switching: _audioSwitching,
      release: _readiness.release,
      timing: micRecoveryTiming,
      // An injected room has no sound stack to watch unless a test brings one.
      watchDevices: audioDevices != null || roomFactory == null,
      osMicBlocked: osMicBlocked,
    );
    _share = VoiceScreenShare(
      VoiceScreenShareHost(
        room: () => _room,
        noteError: (error) => _lastError = error,
        refresh: _refreshParticipants,
        reported: _reported,
      ),
      broadcast: broadcast ?? const MethodChannelBroadcastBridge(),
      desktopSources: desktopSources ?? const WebrtcDesktopSources(),
      isolation: shareAudioIsolation ?? ShareAudioIsolation(),
    );
    _stats = VoiceStatsWiring(
      VoiceStatsWiringHost(
        room: () => _room,
        disposed: () => _disposed,
        audioInputId: () => _audioDevices.inputInUse,
        diag: _diag,
      ),
      _healthWatch.diagnostics,
    );
    _video = VoiceVideoReceive(
      VoiceVideoReceiveHost(
        room: () => _room,
        disposed: () => _disposed,
        refresh: _refreshParticipants,
        syncStall: () => _stall.sync(),
        diag: _diag,
      ),
    );
    _stall = VoiceStallWiring(
      VoiceStallWiringHost(
        room: () => _room,
        disposed: () => _disposed,
        reconnecting: () => health.reconnect.restarting.value,
        receiveQuality: () => _video.quality,
        diag: _diag,
      ),
      sampler: _stats.sampler,
      culler: _video.culler,
    );
    _camera = VoiceCamera(
      _share.host,
      _video.density,
      devices: cameraDevices,
      joinTimeout: cameraJoinTimeout,
    );
    _roster = VoiceRoster(
      VoiceRosterHost(
        refresh: _refreshParticipants,
        reconnecting: () => health.reconnect.restarting.value,
        localVoice: () => gate.fast ? gate.voice : null,
        deafened: () => _listener.deafened,
      ),
    );
    health.reconnect
      ..log = _diag
      ..restarting.addListener(_onReconnectingChanged);
  }

  /// The room a fresh call publishes into: only what is on screen is
  /// subscribed, at the size shown, so several video tiles do not cost the
  /// same as all at full size, plus whatever microphone/speaker Voice
  /// Settings has chosen; see [VoiceAudioDevices].
  lk.Room _buildRoom() => buildRoomWithStartBitrate(
        _audioSwitching.roomOptions(receiveRoomOptions()),
      );

  late final RoomFactory _roomFactory;

  late final VoiceMicRecovery _micRecovery;

  late final _setupLog = LiveKitSetupLog(_diag);

  late final _processing = VoiceProcessingControl(
    switching: _audioSwitching,
    mic: _mic,
    release: _readiness.release,
    micWanted: () => _micRecovery.micWanted,
    restartCapture: _micRecovery.restartCapture,
    reopenMuted: () => _mic.reopenMuted(_plainOpenOptions()),
    log: _diag,
  );

  /// Reopens the capture when it changed; echo, gain and suppression are fixed at open.
  Future<void> setVoiceProcessing(VoiceProcessing next) =>
      _processing.set(next, inCall: _room != null);

  Future<void> _reopenCapture(String reason) =>
      _processing.reopen(reason, inCall: _room != null);

  /// Whether a silent microphone is swapped for another, for this call only.
  void setMicFallbackEnabled(bool enabled) =>
      _micRecovery.fallback.enabled = enabled;

  /// The microphone the call switched to on its own, until dismissed.
  String? get micFallbackNotice => _micRecovery.fallback.notice;
  Stream<String?> get micFallbackNotices => _micRecovery.fallback.notices;
  void dismissMicFallbackNotice() => _micRecovery.fallback.dismissNotice();

  /// Whether the mic is healthy, being brought back, or given up on.
  MicStatus get micStatus => _micRecovery.status;
  Stream<MicStatus> get micStatuses => _micRecovery.statuses;

  /// Why the last attempt to open the microphone failed; null while it works.
  MicFailureReason? get micFailure => _micRecovery.failure;
  Stream<MicFailureReason?> get micFailures => _micRecovery.failures;

  /// Force-restarts the capture; the tap on a mic button that says it is unavailable.
  Future<bool> resetMicrophone() => _micRecovery.reset();

  /// Into the app's debug log when the app wired one, so a tester's export shows it.
  void _diag(String line, {LogLevel level = LogLevel.info}) =>
      (_listener.audio.log ?? _appLogVoice)(line, level: level);

  static void _appLogVoice(String line, {LogLevel level = LogLevel.info}) =>
      AppLog.at(level, LogTag.voice, line);

  late final _healthWatch = VoiceHealthWatch(
    VoiceHealthWatchHost(room: () => _room, diag: _diag),
  );

  /// Per-person quality and the last call's summary; see [VoiceHealth].
  VoiceHealth get health => _healthWatch.health;

  /// What a call report needs, kept apart from the debug log; see [CallDiagnostics].
  CallDiagnostics get diagnostics => _healthWatch.diagnostics;

  late final MicPort _mic;
  late final VoiceInputGate _inputGate;

  InputGateMonitor get _gate => _inputGate.gate;

  late final VoiceAudioDevices _audioDevices;

  AudioDeviceSwitching get _audioSwitching => _audioDevices.switching;

  /// Whether picking a specific microphone actually changes the live call.
  bool get supportsAudioInputSelection => _audioDevices.supportsInputSelection;

  /// Whether picking a specific speaker actually changes playback.
  bool get supportsAudioOutputSelection =>
      _audioDevices.supportsOutputSelection;

  /// The id of the speaker playback is routed to, null for the system default.
  String? get audioOutputInUse => _audioDevices.outputInUse;

  /// The id of the microphone capture is on, null for the system default.
  String? get audioInputInUse => _audioDevices.inputInUse;

  /// Fires when the platform's own device list changes, so a picker can refresh without polling.
  Stream<void> get audioDeviceChanges => _audioDevices.changes;

  /// The microphones this platform offers, for the picker.
  Future<List<AudioDevice>> audioInputDevices() => _audioDevices.inputs();

  /// The speakers this platform offers, for the picker.
  Future<List<AudioDevice>> audioOutputDevices() => _audioDevices.outputs();

  /// Switches the published microphone to [device] (null for the system
  /// default), live where this platform honours it, and remembered for the
  /// next join either way.
  Future<bool> selectAudioInputDevice(AudioDevice? device) =>
      _audioDevices.selectInput(device, remember: true);

  /// [selectAudioInputDevice]'s counterpart for local playback.
  Future<bool> selectAudioOutputDevice(AudioDevice? device) =>
      _audioDevices.selectOutput(device, remember: true);

  lk.AudioCaptureOptions _openCaptureOptions({required bool reopen}) =>
      _audioDevices.openCaptureOptions(reopen: reopen);

  bool get supportsInputGate => _inputGate.supported;

  /// Your microphone's level and voice state, while in a call.
  Stream<InputGateReading> get inputGateReadings => _gate.readings;

  /// Your microphone's level as the SFU last reported it, for hosts with no input gate.
  Stream<double> get localAudioLevels => _roster.localLevels;

  /// Sets the native gate; [enabled] false keeps metering but stops silencing.
  void setInputGate({required bool enabled, required double thresholdDb}) =>
      _inputGate.setGate(enabled: enabled, thresholdDb: thresholdDb);

  /// Where the automatic threshold currently sits.
  Stream<double> get autoInputThresholds => _inputGate.autoThresholds;

  /// The threshold the native gate is using right now.
  double get inputThresholdDb => _inputGate.thresholdDb;

  /// Hands the threshold to the automatic noise-floor estimator, or takes it back.
  void setAutoInputThreshold(bool enabled) =>
      _inputGate.setAutoThreshold(enabled);

  /// Whether a meter is on screen in a focused app, which raises the reading rate.
  void setLevelDisplayed(bool displayed) =>
      _inputGate.setLevelDisplayed(displayed);

  /// Softens shouts and caps sudden peaks where the host gates natively.
  void setEvenOutLoudSounds(bool enabled) =>
      _inputGate.setEvenOutLoudSounds(enabled);

  /// Runs rnnoise on the microphone ahead of the gate; [strongest] adds DeepFilterNet.
  void setStrongNoiseSuppression(bool enabled, {bool strongest = false}) =>
      _inputGate.setStrongNoiseSuppression(enabled, strongest: strongest);

  late final VoiceMicReadiness _readiness;

  lk.AudioCaptureOptions _plainOpenOptions() =>
      _openCaptureOptions(reopen: false);

  /// Keeps the capture open while muted, so push to talk keys down instantly.
  Future<void> setKeepMicReady(bool keepReady) =>
      _readiness.setKeepReady(keepReady);

  /// A phone that goes to the background releases a muted microphone at once.
  void setAppBackgrounded(bool backgrounded) =>
      _readiness.setBackgrounded(backgrounded);

  late final _listener = VoiceListenerAudio(
    VoiceListenerAudioHost(
      room: () => _room,
      noteError: (error) => _lastError = error,
      refresh: _refreshParticipants,
    ),
  );

  /// Whether the listener is deafened; see [setDeafened].
  bool get deafened => _listener.deafened;

  /// Whether [identity] is silenced for this listener alone.
  bool isLocallyMuted(String identity) => _listener.isLocallyMuted(identity);

  /// Whether this host can change one participant's volume at all.
  bool get supportsParticipantVolume => _listener.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _listener.volumeFor(identity);

  /// Sets [identity]'s playback gain for this listener only.
  Future<void> setVolumeFor(String identity, double volume) =>
      _listener.setVolumeFor(identity, volume);

  /// [identity]'s screen share audio gain, kept apart from their voice.
  double screenVolumeFor(String identity) =>
      _listener.screenVolumeFor(identity);

  /// Sets [identity]'s screen share audio gain for this listener only.
  Future<void> setScreenVolumeFor(String identity, double volume) =>
      _listener.setScreenVolumeFor(identity, volume);

  /// Whether [identity]'s screen share audio alone is silenced for you.
  bool isScreenAudioMuted(String identity) =>
      _listener.isScreenAudioMuted(identity);

  /// Silences (or restores) only [identity]'s screen share audio.
  Future<void> setScreenAudioMuted(String identity, bool muted) =>
      _listener.setScreenAudioMuted(identity, muted);

  /// Whether [identity] is publishing screen share audio right now.
  bool hasScreenAudio(String identity) => _listener.hasScreenAudio(identity);

  /// Why the last gain change to [identity] did not land, or null if it did.
  Object? volumeFailureFor(String identity, {bool screen = false}) =>
      _listener.volumeFailureFor(identity, screen: screen);

  /// Silences (or restores) one participant, for this listener only.
  Future<void> setLocallyMuted(String identity, bool muted) =>
      _listener.setLocallyMuted(identity, muted);

  /// Silences (or restores) every remote participant locally; false when there is no call to affect.
  Future<bool> setDeafened(bool deafened) => _listener.setDeafened(deafened);

  final JoinTimings _joinTimings;
  late final VoiceCamera _camera;
  late final VoiceRoster _roster;
  late final VoiceScreenShare _share;
  late final VoiceVideoReceive _video;
  late final VoiceStallWiring _stall;
  late final VoiceStatsWiring _stats;

  /// Per-track video stats, sampled while somebody watches, listens or we publish video.
  CallStatsSampler get callStats => _stats.sampler;

  lk.Room? _room;
  // room.events.listen returns a cancel function rather than a
  // StreamSubscription, so this holds the canceller itself.
  lk.CancelListenFunc? _cancelEvents;
  void Function()? _stopArrivalWatch;

  final _stateController = StreamController<VoiceSessionState>.broadcast();

  VoiceSessionState _state = VoiceSessionState.idle;
  Object? _lastError;
  VoiceDisconnect? _lastDisconnect;
  bool _disposed = false;

  VoiceSessionState get state => _state;
  Stream<VoiceSessionState> get states => _stateController.stream;

  List<VoiceParticipant> get participants => _roster.participants;
  Stream<List<VoiceParticipant>> get participantChanges => _roster.changes;

  /// Whether this host can add a real audio track to a screen share; see
  /// [rtc_share_audio.supportsScreenShareAudio] for the per-platform trace.
  bool get supportsScreenShareAudio =>
      rtc_share_audio.supportsScreenShareAudio();

  /// How readily [VoiceParticipant.isSpeaking] reports true; see
  /// [passesActivationThreshold] for what this can and cannot do.
  ///
  /// Safe before a room exists, and live mid-call: it re-evaluates the roster.
  void setSpeakingSensitivity(double sensitivity) =>
      _roster.setSensitivity(sensitivity);

  /// Caps the sharpness of the remote video you watch; live mid-call, and
  /// kept for the next join.
  void setReceiveVideoQuality(ReceiveVideoQuality quality) =>
      _video.setQuality(quality);

  /// Keeps the tile [tileKey] at full sharpness, whatever the receive quality, until the result is called.
  VoidCallback holdEnlargedVideo(String tileKey) =>
      _video.holdEnlarged(tileKey);

  /// How sharp your camera publishes. Read when the camera turns on, and a
  /// different one than it was published at republishes; the app cycles a live
  /// camera to apply a change.
  void setCameraQuality(CameraQuality quality) => _camera.quality = quality;

  /// Why the last attempt failed, when [state] is [VoiceSessionState.failed].
  Object? get lastError => _lastError;

  /// Why the last call ended, when the SFU ended it rather than this client.
  VoiceDisconnect? get lastDisconnect => _lastDisconnect;

  /// Whether the call the SFU just ended was sharing a screen, read before the roster emptied.
  bool get droppedWhileSharing => _droppedWhileSharing;
  bool _droppedWhileSharing = false;

  /// The camera a join asked for opens after "connected"; this reports its start, failure and end.
  Stream<CameraJoinOpen> get cameraJoinOpens => _camera.joinOpens;

  /// The in-flight join, so a second call serializes behind it; see [join].
  Future<void>? _joining;

  /// Bumped by every join and every leave, so a teardown still unwinding can
  /// tell that a newer call has taken this session over; see [leave].
  int _generation = 0;

  /// Joins a room with a server-minted token; [canPublish] only stops a listen-only join from opening the microphone, and rejoining leaves the old connection first.
  /// Overlapping calls serialize, so a second tap or a channel switch mid-connect waits and the state ends as the last caller asked.
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) {
    final previous = _joining ?? Future<void>.value();
    final current = previous
        .catchError(ignoreError(LogTag.voice,
            'An earlier call setup step failed; it was already reported'))
        .then(
          (_) => _join(
            url: url,
            token: token,
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
            canPublish: canPublish,
          ),
        );
    _joining = current.whenComplete(() {
      if (identical(_joining, current)) _joining = null;
    });
    return current;
  }

  /// Leaves the call and resets deafen and mutes with it. Safe to call when not in one.
  ///
  /// A leave a newer join already superseded resets nothing: [_teardown] clears `_room` before it awaits.
  Future<void> leave() async {
    final generation = ++_generation;
    await _teardown();
    if (generation != _generation) return;
    _roster.set(const []);
    _listener.resetForNewCall();
    // Gain deliberately survives: somebody you turned down stays turned down.
    _lastDisconnect = null;
    _droppedWhileSharing = false;
    _video.resetForNewCall();
    _setState(VoiceSessionState.idle);
  }

  /// Whether starting a share here must name a source first.
  bool get screenShareNeedsSource => _share.desktopSources.required;

  /// Whether more than one enumerated source is worth asking a person to
  /// pick between; see [DesktopSources.sourcePickerUseful].
  bool get screenShareSourcePickerUseful =>
      _share.desktopSources.sourcePickerUseful;

  /// The screens this desktop will let the app capture.
  ///
  /// Calling this is what makes a later [setScreenShareEnabled] able to find
  /// anything at all: see [DesktopSources].
  Future<List<ScreenShareSource>> screenShareSources() => _share.sources();

  /// Mutes or unmutes the local microphone; returns whether it ended in the requested state, since a token without SPEAK or a denied OS permission mean no and the UI must show what happened.
  Future<bool> setMicrophoneEnabled(bool enabled) =>
      _micRecovery.setEnabled(enabled);

  /// Enables or disables the local camera live, mid-call.
  Future<bool> setCameraEnabled(bool enabled) => _camera.trySetEnabled(enabled);

  /// Starts or stops sharing a screen, bounded by [quality] and the space-wide [maxHeight] ceiling.
  /// Reports what happened rather than what was asked for; on iOS those differ, see [ScreenShareOutcome].
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) =>
      _share.setEnabled(
        enabled,
        ShareRequest(quality, sourceId, includeAudio, maxHeight),
      );

  /// The source id of a share that stopped because its window or screen went away.
  Stream<String> get screenShareSourceLost => _share.sourceWatch.lost;

  /// Whether the running share carries an audio track to switch.
  bool get screenShareHasAudio => _share.hasAudio;

  /// Whether the running share's audio is silenced.
  bool get screenShareAudioMuted => _share.audioMuted;

  /// Silences or restores the share's audio while it keeps running.
  Future<bool> setScreenShareAudioMuted(bool muted) =>
      _share.setAudioMuted(muted);

  /// The widget that renders [identity]'s shared screen; a plain [Widget] so no LiveKit type crosses the package seam.
  Widget screenShareViewFor(String identity) =>
      _share.view(identity, _video.density);

  /// Per tile key (`<kind>:<identity>`), what each remote video's tile should
  /// say beyond its picture: paused by the server, stalled and recovering, or
  /// stopped. A tile missing from the map is playing normally.
  ValueListenable<Map<String, VideoTileHealth>> get videoHealth =>
      _stall.watchdog.health;

  /// The widget that renders [identity]'s live camera feed, the local participant's included.
  Widget cameraViewFor(String identity) => _camera.view(identity);

  /// Declares which `'<kind>:<identity>'` tiles want video so the rest can be unsubscribed; null means no opinion.
  /// See [VideoSubscriptionCuller] for the timing.
  void setVideoInterest(Set<String>? tileKeys) => _video.setInterest(tileKeys);

  /// Keeps the screen-share (or camera) tiles named by [tileKeys] unsubscribed
  /// whatever the interest says, along with a share's own audio, so a viewer
  /// who stopped watching pays no bandwidth or decode for it.
  void setVideoBlocked(Set<String> tileKeys) => _video.setBlocked(tileKeys);

  /// Whether flipping needs no chosen device; see [CameraSwitching.canFlip].
  bool get canFlipCamera => _camera.switching.canFlip;

  /// Whether picking a camera needs one named first; see
  /// [CameraSwitching.needsSelection].
  bool get cameraNeedsSelection => _camera.switching.needsSelection;

  /// The cameras this desktop (or browser) offers, for the picker. Calling
  /// this is what makes a later [selectCameraDevice] able to find anything,
  /// the same reason [screenShareSources] has to run first.
  Future<List<CameraDevice>> cameraDevices() => _camera.devices();

  /// Flips the published camera between front and back, mobile only.
  Future<bool> flipCamera() => _camera.flip();

  /// Switches the published camera to [device], desktop's answer to
  /// [flipCamera] where more than one webcam can exist.
  Future<bool> selectCameraDevice(CameraDevice device) =>
      _camera.select(device);

  Future<T> _reported<T>(String action, T fallback, Future<T> Function() run) =>
      runReported(action, fallback, run, (error) => _lastError = error);

  void _refreshParticipants() {
    _inputGate.applyRate();
    final room = _room;
    if (room == null || _disposed) return;
    // Reapplied on every refresh, not only on toggle, so deafening reaches a participant or track that appears afterward too.
    unawaited(_listener.apply(room));
    // Ahead of the unchanged-roster early return: a subscription can change with no visible roster change at all.
    _video.applyInterest();
    unawaited(_video.applyQuality(room));
    _roster.update(room);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _video.dispose();
    _share.dispose();
    await _stall.dispose();
    await callStats.dispose();
    health.dispose();
    _joinTimings.finish();
    // After `_teardown`, or its own `resetFacing()` writes past disposal.
    await _teardown();
    await _camera.dispose();
    await _inputGate.dispose();
    await _micRecovery.dispose();
    await _gate.dispose();
    await _stateController.close();
    await _roster.dispose();
  }
}

/// Lets tests see the watch behind [VoiceSession.health]; an extension rather
/// than a member so fakes implementing [VoiceSession] need not provide it.
@visibleForTesting
extension VoiceSessionHealthWatchAccess on VoiceSession {
  AudioGlitchWatch get glitchWatch => _healthWatch.glitchWatch;
}
