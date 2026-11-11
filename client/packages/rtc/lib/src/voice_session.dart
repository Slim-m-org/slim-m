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
///
/// Every public member is declared here and forwards to a collaborator
/// (`VoiceSessionCore` wires them): several tests build a `FakeSession
/// implements VoiceSession` so that a member added to the real session is a
/// compile error there rather than a silently untested path.
library;

import 'package:flutter/foundation.dart'
    show ValueListenable, VoidCallback, visibleForTesting;
import 'package:flutter/widgets.dart' show Widget;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
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
import 'mic_failure.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';
import 'mic_release.dart';
import 'pulse_audio.dart';
import 'screen_share.dart';
import 'screen_share_audio.dart' as rtc_share_audio;
import 'screen_share_local.dart';
import 'share_audio_isolation.dart';
import 'video_quality.dart';
import 'video_stall_watchdog.dart';
import 'video_subscription_culler.dart';
import 'voice_health.dart';
import 'voice_log.dart';
import 'voice_models.dart';
import 'voice_processing.dart';
import 'voice_session_core.dart';

export 'voice_first_audio.dart' show watchFirstAudio;
export 'voice_session_core.dart' show RoomFactory;

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
  }) : _core = VoiceSessionCore(
          roomFactory: roomFactory,
          broadcast: broadcast,
          desktopSources: desktopSources,
          cameraDevices: cameraDevices,
          inputGate: inputGate,
          micPort: micPort,
          audioLog: audioLog,
          audioDevices: audioDevices,
          liveOutput: liveOutput,
          liveInput: liveInput,
          pulse: pulse,
          osMicBlocked: osMicBlocked,
          micRecoveryTiming: micRecoveryTiming,
          micReleaseGrace: micReleaseGrace,
          mobile: mobile,
          joinTimings: joinTimings,
          shareAudioIsolation: shareAudioIsolation,
          cameraJoinTimeout: cameraJoinTimeout,
        );

  final VoiceSessionCore _core;

  // Call lifecycle and state.

  VoiceSessionState get state => _core.flow.state;
  Stream<VoiceSessionState> get states => _core.flow.states;

  List<VoiceParticipant> get participants => _core.roster.participants;
  Stream<List<VoiceParticipant>> get participantChanges => _core.roster.changes;

  /// Why the last attempt failed, when [state] is [VoiceSessionState.failed].
  Object? get lastError => _core.lastError;

  /// Why the last call ended, when the SFU ended it rather than this client.
  VoiceDisconnect? get lastDisconnect => _core.flow.lastDisconnect;

  /// Whether the call the SFU just ended was sharing a screen, read before the roster emptied.
  bool get droppedWhileSharing => _core.flow.droppedWhileSharing;

  /// Joins a room with a server-minted token; [canPublish] only stops a listen-only join from opening the microphone, and rejoining leaves the old connection first.
  /// Overlapping calls serialize, so a second tap or a channel switch mid-connect waits and the state ends as the last caller asked.
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) =>
      _core.flow.join(
        url: url,
        token: token,
        microphoneEnabled: microphoneEnabled,
        cameraEnabled: cameraEnabled,
        canPublish: canPublish,
      );

  /// Leaves the call and resets deafen and mutes with it. Safe to call when not in one.
  Future<void> leave() => _core.flow.leave();

  Future<void> dispose() => _core.flow.dispose();

  /// Per-person quality and the last call's summary; see [VoiceHealth].
  VoiceHealth get health => _core.healthWatch.health;

  /// What a call report needs, kept apart from the debug log; see [CallDiagnostics].
  CallDiagnostics get diagnostics => _core.healthWatch.diagnostics;

  /// Per-track video stats, sampled while somebody watches, listens or we publish video.
  CallStatsSampler get callStats => _core.stats.sampler;

  /// How readily [VoiceParticipant.isSpeaking] reports true; see
  /// [passesActivationThreshold] for what this can and cannot do.
  ///
  /// Safe before a room exists, and live mid-call: it re-evaluates the roster.
  void setSpeakingSensitivity(double sensitivity) =>
      _core.roster.setSensitivity(sensitivity);

  // Microphone.

  /// Mutes or unmutes the local microphone; returns whether it ended in the requested state, since a token without SPEAK or a denied OS permission mean no and the UI must show what happened.
  Future<bool> setMicrophoneEnabled(bool enabled) =>
      _core.micRecovery.setEnabled(enabled);

  /// Whether the mic is healthy, being brought back, or given up on.
  MicStatus get micStatus => _core.micRecovery.status;
  Stream<MicStatus> get micStatuses => _core.micRecovery.statuses;

  /// Why the last attempt to open the microphone failed; null while it works.
  MicFailureReason? get micFailure => _core.micRecovery.failure;
  Stream<MicFailureReason?> get micFailures => _core.micRecovery.failures;

  /// Force-restarts the capture; the tap on a mic button that says it is unavailable.
  Future<bool> resetMicrophone() => _core.micRecovery.reset();

  /// Whether a silent microphone is swapped for another, for this call only.
  void setMicFallbackEnabled(bool enabled) =>
      _core.micRecovery.fallback.enabled = enabled;

  /// The microphone the call switched to on its own, until dismissed.
  String? get micFallbackNotice => _core.micRecovery.fallback.notice;
  Stream<String?> get micFallbackNotices => _core.micRecovery.fallback.notices;
  void dismissMicFallbackNotice() => _core.micRecovery.fallback.dismissNotice();

  /// Keeps the capture open while muted, so push to talk keys down instantly.
  Future<void> setKeepMicReady(bool keepReady) =>
      _core.readiness.setKeepReady(keepReady);

  /// A phone that goes to the background releases a muted microphone at once.
  void setAppBackgrounded(bool backgrounded) =>
      _core.readiness.setBackgrounded(backgrounded);

  /// Reopens the capture when it changed; echo, gain and suppression are fixed at open.
  Future<void> setVoiceProcessing(VoiceProcessing next) =>
      _core.processing.set(next, inCall: _core.flow.room != null);

  // Microphone input gate and level.

  bool get supportsInputGate => _core.micGate.supported;

  /// Your microphone's level and voice state, while in a call.
  Stream<InputGateReading> get inputGateReadings => _core.micGate.gate.readings;

  /// Your microphone's level as the SFU last reported it, for hosts with no input gate.
  Stream<double> get localAudioLevels => _core.roster.localLevels;

  /// Sets the native gate; [enabled] false keeps metering but stops silencing.
  void setInputGate({required bool enabled, required double thresholdDb}) =>
      _core.micGate.setGate(enabled: enabled, thresholdDb: thresholdDb);

  /// Where the automatic threshold currently sits.
  Stream<double> get autoInputThresholds => _core.micGate.autoThresholds;

  /// The threshold the native gate is using right now.
  double get inputThresholdDb => _core.micGate.thresholdDb;

  /// Hands the threshold to the automatic noise-floor estimator, or takes it back.
  void setAutoInputThreshold(bool enabled) =>
      _core.micGate.setAutoThreshold(enabled);

  /// Whether a meter is on screen in a focused app, which raises the reading rate.
  void setLevelDisplayed(bool displayed) =>
      _core.micGate.setLevelDisplayed(displayed);

  /// Softens shouts and caps sudden peaks where the host gates natively.
  void setEvenOutLoudSounds(bool enabled) =>
      _core.micGate.setEvenOutLoudSounds(enabled);

  /// Runs rnnoise on the microphone ahead of the gate; [strongest] adds DeepFilterNet.
  void setStrongNoiseSuppression(bool enabled, {bool strongest = false}) =>
      _core.micGate.setStrongNoiseSuppression(enabled, strongest: strongest);

  // Audio devices.

  /// Whether picking a specific microphone actually changes the live call.
  bool get supportsAudioInputSelection => _core.devices.supportsInputSelection;

  /// Whether picking a specific speaker actually changes playback.
  bool get supportsAudioOutputSelection =>
      _core.devices.supportsOutputSelection;

  /// The id of the speaker playback is routed to, null for the system default.
  String? get audioOutputInUse => _core.devices.outputInUse;

  /// The id of the microphone capture is on, null for the system default.
  String? get audioInputInUse => _core.devices.inputInUse;

  /// Fires when the platform's own device list changes, so a picker can refresh without polling.
  Stream<void> get audioDeviceChanges => _core.devices.changes;

  /// The microphones this platform offers, for the picker.
  Future<List<AudioDevice>> audioInputDevices() => _core.devices.inputs();

  /// The speakers this platform offers, for the picker.
  Future<List<AudioDevice>> audioOutputDevices() => _core.devices.outputs();

  /// Switches the published microphone to [device] (null for the system
  /// default), live where this platform honours it, and remembered for the
  /// next join either way.
  Future<bool> selectAudioInputDevice(AudioDevice? device) =>
      _core.devices.selectInput(device, remember: true);

  /// [selectAudioInputDevice]'s counterpart for local playback.
  Future<bool> selectAudioOutputDevice(AudioDevice? device) =>
      _core.devices.selectOutput(device, remember: true);

  // What this listener hears: deafen, per-participant mute and gain.

  bool get deafened => _core.listener.deafened;

  /// Whether [identity] is silenced for this listener alone.
  bool isLocallyMuted(String identity) =>
      _core.listener.isLocallyMuted(identity);

  /// Whether this host can change one participant's volume at all.
  bool get supportsParticipantVolume =>
      _core.listener.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _core.listener.volumeFor(identity);

  /// Sets [identity]'s playback gain for this listener only, clamped to the range the UI offers.
  Future<void> setVolumeFor(String identity, double volume) =>
      _core.listener.setVolumeFor(identity, volume);

  /// [identity]'s screen share audio gain, kept apart from their voice.
  double screenVolumeFor(String identity) =>
      _core.listener.screenVolumeFor(identity);

  /// Sets [identity]'s screen share audio gain for this listener only.
  Future<void> setScreenVolumeFor(String identity, double volume) =>
      _core.listener.setScreenVolumeFor(identity, volume);

  /// Whether [identity]'s screen share audio alone is silenced for you.
  bool isScreenAudioMuted(String identity) =>
      _core.listener.isScreenAudioMuted(identity);

  /// Silences (or restores) only [identity]'s screen share audio.
  Future<void> setScreenAudioMuted(String identity, bool muted) =>
      _core.listener.setScreenAudioMuted(identity, muted);

  /// Whether [identity] is publishing screen share audio right now.
  bool hasScreenAudio(String identity) =>
      _core.listener.hasScreenAudio(identity);

  /// Why the last gain change to [identity] did not land, or null if it did.
  Object? volumeFailureFor(String identity, {bool screen = false}) =>
      _core.listener.volumeFailureFor(identity, screen: screen);

  /// Silences (or restores) one participant, for this listener only.
  Future<void> setLocallyMuted(String identity, bool muted) =>
      _core.listener.setLocallyMuted(identity, muted);

  /// Silences (or restores) every remote participant locally; false when there is no call to affect.
  Future<bool> setDeafened(bool deafened) =>
      _core.listener.setDeafened(deafened);

  // Screen share.

  /// Whether this host can add a real audio track to a screen share; see
  /// [rtc_share_audio.supportsScreenShareAudio] for the per-platform trace.
  bool get supportsScreenShareAudio =>
      rtc_share_audio.supportsScreenShareAudio();

  /// Whether starting a share here must name a source first.
  bool get screenShareNeedsSource => _core.share.desktopSources.required;

  /// Whether more than one enumerated source is worth asking a person to
  /// pick between; see [DesktopSources.sourcePickerUseful].
  bool get screenShareSourcePickerUseful =>
      _core.share.desktopSources.sourcePickerUseful;

  /// The screens this desktop will let the app capture.
  ///
  /// Calling this is what makes a later [setScreenShareEnabled] able to find
  /// anything at all: see [DesktopSources].
  Future<List<ScreenShareSource>> screenShareSources() => _core.share.sources();

  /// Starts or stops sharing a screen, bounded by [quality] and the space-wide [maxHeight] ceiling.
  /// Reports what happened rather than what was asked for; on iOS those differ, see [ScreenShareOutcome].
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) =>
      _core.share.setEnabled(
        enabled,
        ShareRequest(quality, sourceId, includeAudio, maxHeight),
      );

  /// The source id of a share that stopped because its window or screen went away.
  Stream<String> get screenShareSourceLost => _core.share.sourceWatch.lost;

  /// Whether the running share carries an audio track to switch.
  bool get screenShareHasAudio => _core.share.hasAudio;

  /// Whether the running share's audio is silenced.
  bool get screenShareAudioMuted => _core.share.audioMuted;

  /// Silences or restores the share's audio while it keeps running.
  Future<bool> setScreenShareAudioMuted(bool muted) =>
      _core.share.setAudioMuted(muted);

  /// The widget that renders [identity]'s shared screen; a plain [Widget] so no LiveKit type crosses the package seam.
  Widget screenShareViewFor(String identity) =>
      _core.share.view(identity, _core.video.density);

  // Camera.

  /// Enables or disables the local camera live, mid-call.
  Future<bool> setCameraEnabled(bool enabled) =>
      _core.camera.trySetEnabled(enabled);

  /// How sharp your camera publishes. Read when the camera turns on, and a
  /// different one than it was published at republishes; the app cycles a live
  /// camera to apply a change.
  void setCameraQuality(CameraQuality quality) =>
      _core.camera.quality = quality;

  /// The camera a join asked for opens after "connected"; this reports its start, failure and end.
  Stream<CameraJoinOpen> get cameraJoinOpens => _core.camera.joinOpens;

  /// The widget that renders [identity]'s live camera feed, the local participant's included.
  Widget cameraViewFor(String identity) => _core.camera.view(identity);

  /// Whether flipping needs no chosen device; see [CameraSwitching.canFlip].
  bool get canFlipCamera => _core.camera.switching.canFlip;

  /// Whether picking a camera needs one named first; see
  /// [CameraSwitching.needsSelection].
  bool get cameraNeedsSelection => _core.camera.switching.needsSelection;

  /// The cameras this desktop (or browser) offers, for the picker. Calling
  /// this is what makes a later [selectCameraDevice] able to find anything,
  /// the same reason [screenShareSources] has to run first.
  Future<List<CameraDevice>> cameraDevices() => _core.camera.devices();

  /// Flips the published camera between front and back, mobile only.
  Future<bool> flipCamera() => _core.camera.flip();

  /// Seeds the webcam from an earlier call; see [VoiceCamera.preferredDeviceId].
  void setPreferredCameraId(String? id) => _core.camera.preferredDeviceId = id;

  /// Switches the published camera to [device], desktop's answer to
  /// [flipCamera] where more than one webcam can exist.
  Future<bool> selectCameraDevice(CameraDevice device) =>
      _core.camera.select(device);

  // Remote video.

  /// Per tile key (`<kind>:<identity>`), what each remote video's tile should
  /// say beyond its picture: paused by the server, stalled and recovering, or
  /// stopped. A tile missing from the map is playing normally.
  ValueListenable<Map<String, VideoTileHealth>> get videoHealth =>
      _core.stall.watchdog.health;

  /// Caps the sharpness of the remote video you watch; live mid-call, and
  /// kept for the next join.
  void setReceiveVideoQuality(ReceiveVideoQuality quality) =>
      _core.video.setQuality(quality);

  /// Keeps the tile [tileKey] at full sharpness, whatever the receive quality, until the result is called.
  VoidCallback holdEnlargedVideo(String tileKey) =>
      _core.video.holdEnlarged(tileKey);

  /// Declares which `'<kind>:<identity>'` tiles want video so the rest can be unsubscribed; null means no opinion.
  /// See [VideoSubscriptionCuller] for the timing.
  void setVideoInterest(Set<String>? tileKeys) =>
      _core.video.setInterest(tileKeys);

  /// Keeps the screen-share (or camera) tiles named by [tileKeys] unsubscribed
  /// whatever the interest says, along with a share's own audio, so a viewer
  /// who stopped watching pays no bandwidth or decode for it.
  void setVideoBlocked(Set<String> tileKeys) =>
      _core.video.setBlocked(tileKeys);
}

/// Lets tests see the watch behind [VoiceSession.health]; an extension rather
/// than a member so fakes implementing [VoiceSession] need not provide it.
@visibleForTesting
extension VoiceSessionHealthWatchAccess on VoiceSession {
  AudioGlitchWatch get glitchWatch => _core.healthWatch.glitchWatch;
}
