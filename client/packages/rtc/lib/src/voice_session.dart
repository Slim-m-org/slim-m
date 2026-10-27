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

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_event_scope.dart';
import 'audio_gain.dart' as rtc_gain;
import 'audio_glitch_watch.dart';
import 'audio_stats.dart';
import 'capture_noise_suppression.dart';
import 'mic_port.dart';
import 'mic_release.dart';
import 'input_gate.dart';
import 'join_timings.dart';
import 'mic_failure.dart';
import 'mic_fallback.dart';
import 'mic_recovery.dart';
import 'noise_floor_estimator.dart';
import 'speaking_hold.dart';
import 'local_audio.dart';
import 'screen_share_audio.dart' as rtc_share_audio;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
import 'broadcast_bridge.dart';
import 'call_stats.dart';
import 'call_stats_sampler.dart';
import 'camera_devices.dart';
import 'camera_switching.dart';
import 'camera_view.dart';
import 'desktop_sources.dart';
import 'remote_video_publication.dart';
import 'screen_share.dart';
import 'screen_share_audio_mute.dart';
import 'screen_share_control.dart';
import 'screen_share_publish.dart';
import 'screen_share_view.dart';
import 'share_audio_isolation.dart';
import 'voice_disconnect_reason.dart';
import 'video_quality.dart';
import 'video_stall_watchdog.dart';
import 'video_subscription_culler.dart';
import 'voice_health.dart';
import 'voice_log.dart';
import 'voice_models.dart';
import 'voice_roster_snapshot.dart';
import 'package:slimm_api/api.dart'
    show AppLog, LogLevel, LogTag, reportFailure, ignoreError;

part 'voice_session_audio_devices.dart';
part 'voice_session_health.dart';
part 'voice_session_input_gate.dart';
part 'voice_session_join.dart';
part 'voice_session_listener_audio.dart';
part 'voice_session_mic_fallback.dart';
part 'voice_session_mic_recovery.dart';
part 'voice_session_mic_release.dart';
part 'voice_session_stall.dart';
part 'voice_session_stats.dart';
part 'voice_session_tracks.dart';
part 'voice_session_video.dart';

/// Builds the LiveKit room a session drives. The injection seam.
typedef RoomFactory = lk.Room Function();

/// A voice call in one channel.
///
/// Not a singleton and not global: one session is one call, and the caller owns
/// its lifetime. [dispose] must be called, and leaving is not the same as
/// disposing, because a user can leave and rejoin without the surrounding
/// screen being torn down.
class VoiceSession
    with
        VoiceSessionAudioDevices,
        VoiceSessionHealth,
        VoiceSessionInputGate,
        VoiceSessionMicFallback,
        VoiceSessionMicRecovery,
        VoiceSessionMicRelease,
        VoiceSessionListenerAudio {
  VoiceSession({
    RoomFactory? roomFactory,
    BroadcastBridge? broadcast,
    DesktopSources? desktopSources,
    CameraDevices? cameraDevices,
    InputGateMonitor? inputGate,
    MicPort? micPort,
    Duration? captureRestartDebounce,
    VoiceLog? audioLog,
    AudioDevices? audioDevices,
    LiveOutputSwitch? liveOutput,
    LiveInputSwitch? liveInput,
    OsMicBlockProbe? osMicBlocked,
    MicRecoveryTiming micRecoveryTiming = const MicRecoveryTiming(),
    Duration micReleaseGrace = kMicReleaseGrace,
    bool? mobile,
    JoinTimings? joinTimings,
  })  : _joinTimings = joinTimings ?? JoinTimings(),
        _broadcast = broadcast ?? const MethodChannelBroadcastBridge(),
        _desktopSources = desktopSources ?? const WebrtcDesktopSources(),
        _cameraSwitching = CameraSwitching(
          cameraDevices ?? const HardwareCameraDevices(),
        ) {
    _roomFactory = roomFactory ?? _buildRoom;
    _audio.log = audioLog;
    // An injected room has no native capture behind it to gate.
    _gate = inputGate ??
        (roomFactory == null
            ? InputGateMonitor()
            : InputGateMonitor.disabled());
    _gate.setRate(InputGateRate.watch);
    _initCapture(micPort, captureRestartDebounce, _restartCapture);
    _audioSwitching = _switchingFor(
      audioDevices,
      liveOutput,
      osMicBlocked,
      liveInput,
    );
    _initMicRelease(
      grace: micReleaseGrace,
      mobile: mobile ?? lk.lkPlatformIsMobile(),
      plainOptions: () => _openCaptureOptions(reopen: false),
    );
    _initMicRecovery(
      timing: micRecoveryTiming,
      // An injected room has no sound stack to watch unless a test brings one.
      watchDevices: audioDevices != null || roomFactory == null,
      enable: () => _trySetMicrophone(true),
      afterRestart: _followPreferredDevices,
    );
    _screenShare =
        ScreenShareControl(_broadcast, isolation: ShareAudioIsolation());
    _videoCuller = VideoSubscriptionCuller(onDue: _applyVideoInterest);
  }

  /// The room a fresh call publishes into: only what is on screen is
  /// subscribed, at the size shown, so several video tiles do not cost the
  /// same as all at full size, plus whatever microphone/speaker Voice
  /// Settings has chosen; see [VoiceSessionAudioDevices].
  lk.Room _buildRoom() => lk.Room(
        roomOptions: _audioSwitching.roomOptions(
          receiveRoomOptions(),
          noiseSuppression: _capture.webrtcNoiseSuppression,
        ),
      );

  late final RoomFactory _roomFactory;
  @override
  final JoinTimings _joinTimings;
  final BroadcastBridge _broadcast;
  final DesktopSources _desktopSources;
  final CameraSwitching _cameraSwitching;
  late final ScreenShareControl _screenShare;
  late final VideoSubscriptionCuller _videoCuller;
  final _receiveDensity = ValueNotifier<lk.AdaptiveStreamPixelDensity>(
    lk.AdaptiveStreamPixelDensity.auto,
  );

  /// See [videoHealth]; fed by [callStats] while any remote video is subscribed.
  late final _stallWatchdog = VideoStallWatchdog(recover: _recoverStalledVideo);
  StreamSubscription<CallStatsSnapshot>? _stallStats;
  final _activeVideoKeys = <String>{};

  /// Per-track video stats, sampled only while something is listening.
  late final callStats = CallStatsSampler(
    targets: () => _callStatsTargets(),
    log: (line) => AppLog.debug(LogTag.voice, line),
  );

  @override
  lk.Room? _room;
  // room.events.listen returns a cancel function rather than a
  // StreamSubscription, so this holds the canceller itself.
  lk.CancelListenFunc? _cancelEvents;
  void Function()? _stopArrivalWatch;

  final _stateController = StreamController<VoiceSessionState>.broadcast();
  final _participantsController =
      StreamController<List<VoiceParticipant>>.broadcast();

  @override
  VoiceSessionState _state = VoiceSessionState.idle;
  List<VoiceParticipant> _participants = const [];
  Object? _lastError;
  VoiceDisconnect? _lastDisconnect;
  bool _disposed = false;

  /// See [setSpeakingSensitivity]; 1.0 is the behaviour before the setting.
  double _speakingSensitivity = 1.0;

  ReceiveVideoQuality _receiveQuality = ReceiveVideoQuality.auto;
  final _loweredVideoSids = <String>{};
  CameraQuality _cameraQuality = CameraQuality.balanced;

  /// See [SpeakingHold]; the timer drops a held ring when its time is up.
  final SpeakingHold _speakingHold = SpeakingHold();
  Timer? _speakingHoldTimer;

  VoiceSessionState get state => _state;
  Stream<VoiceSessionState> get states => _stateController.stream;

  List<VoiceParticipant> get participants => _participants;
  Stream<List<VoiceParticipant>> get participantChanges =>
      _participantsController.stream;

  /// Whether this host can add a real audio track to a screen share; see
  /// [rtc_share_audio.supportsScreenShareAudio] for the per-platform trace.
  bool get supportsScreenShareAudio =>
      rtc_share_audio.supportsScreenShareAudio();

  /// How readily [VoiceParticipant.isSpeaking] reports true; see
  /// [passesActivationThreshold] for what this can and cannot do.
  ///
  /// Safe before a room exists, and live mid-call: it re-evaluates the roster.
  void setSpeakingSensitivity(double sensitivity) {
    _speakingSensitivity = sensitivity.clamp(0.0, 1.0);
    _refreshParticipants();
  }

  /// Caps the sharpness of the remote video you watch; live mid-call, and
  /// kept for the next join.
  void setReceiveVideoQuality(ReceiveVideoQuality quality) {
    _receiveQuality = quality;
    _videoCuller.dwell = videoDwellFor(quality);
    _receiveDensity.value = pixelDensityFor(quality);
    _refreshParticipants();
  }

  /// How sharp your camera publishes. Read when the camera turns on, since
  /// capture parameters cannot change on a live track; the app cycles a live
  /// camera to apply a change.
  void setCameraQuality(CameraQuality quality) => _cameraQuality = quality;

  /// Why the last attempt failed, when [state] is [VoiceSessionState.failed].
  Object? get lastError => _lastError;

  /// Why the last call ended, when the SFU ended it rather than this client.
  VoiceDisconnect? get lastDisconnect => _lastDisconnect;

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

  /// Leaves the call. Safe to call when not in one.
  ///
  /// Resets [deafened] along with everything else: there is no room left to
  /// apply it to once this returns, and leaving it set internally would
  /// silently deafen the next call before anyone asked for that, with
  /// nothing in [VoiceState] (which does reset) around to say so.
  ///
  /// None of that happens for a leave a newer join has already superseded:
  /// [_teardown] clears `_room` before it awaits, so a join starting mid-leave
  /// would otherwise have this trailing reset land on top of its new call.
  Future<void> leave() async {
    final generation = ++_generation;
    await _teardown();
    if (generation != _generation) return;
    _participants = const [];
    _audio.deafened = false;
    _audio.muted.clear();
    _audio.screenMuted.clear();
    // Gain deliberately survives: somebody you turned down stays turned down.
    _lastDisconnect = null;
    // Whatever a canvas last asked for was about the call that just ended.
    _videoCuller.setInterest(null);
    _videoCuller.setBlocked(const {});
    if (!_participantsController.isClosed) {
      _participantsController.add(_participants);
    }
    _setState(VoiceSessionState.idle);
  }

  /// Whether starting a share here must name a source first.
  bool get screenShareNeedsSource => _desktopSources.required;

  /// Whether more than one enumerated source is worth asking a person to
  /// pick between; see [DesktopSources.sourcePickerUseful].
  bool get screenShareSourcePickerUseful => _desktopSources.sourcePickerUseful;

  /// The screens this desktop will let the app capture.
  ///
  /// Calling this is what makes a later [setScreenShareEnabled] able to find
  /// anything at all: see [DesktopSources].
  Future<List<ScreenShareSource>> screenShareSources() => _reported(
        'list the screens and windows that can be shared',
        const [],
        _desktopSources.list,
      );

  /// Mutes or unmutes the local microphone; returns whether it ended in the requested state, since a token without SPEAK or a denied OS permission mean no and the UI must show what happened.
  Future<bool> setMicrophoneEnabled(bool enabled) => _trySetMicrophone(enabled);

  /// Enables or disables the local camera live, mid-call. The [join]-time
  /// `cameraEnabled` parameter is only the pre-toggle for before you connect;
  /// this is the same call `toggleMicrophone`'s equivalent already used, now
  /// reachable while already in the call.
  Future<bool> setCameraEnabled(bool enabled) => _trySetCamera(enabled);

  /// Starts or stops sharing a screen, bounded by [quality] and, if given,
  /// [maxHeight] - the space-wide screen-share ceiling, applied on top of
  /// whatever [quality] itself already asked for.
  ///
  /// Reports what happened rather than what was asked for, because on iOS
  /// those differ: see [ScreenShareOutcome]. Stopping asks the platform to end
  /// any broadcast as well as dropping the track, so the two cannot get out of
  /// step and leave a phone still recording with nothing published. The
  /// sequencing that makes iOS actually honour [quality] lives in
  /// [ScreenShareControl]; this method only supplies it a room to act on.
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async {
    final room = _room;
    if (room == null) return ScreenShareOutcome.failed;
    final outcome = await _screenShare.setEnabled(
      enabled,
      quality: quality,
      sourceId: sourceId,
      includeAudio: includeAudio,
      maxHeight: maxHeight,
      publish: (enabled, options, audio) => publishScreenShare(
        room.localParticipant,
        enabled: enabled,
        options: options,
        includeAudio: audio,
        quality: quality,
        maxHeight: maxHeight,
      ),
      isSharing: () => isSharingScreen(room.localParticipant),
      onSettled: (error) {
        if (error != null) _lastError = error;
        _refreshParticipants();
      },
    );
    _refreshParticipants();
    return outcome;
  }

  /// Whether the running share carries an audio track to switch.
  bool get screenShareHasAudio =>
      shareAudioPublication(_room?.localParticipant) != null;

  /// Whether the running share's audio is silenced.
  bool get screenShareAudioMuted =>
      shareAudioPublication(_room?.localParticipant)?.muted ?? false;

  /// Silences or restores the share's audio while it keeps running.
  Future<bool> setScreenShareAudioMuted(bool muted) => _reported(
        'switch the shared audio',
        false,
        () => setShareAudioMuted(_room?.localParticipant, muted),
      );

  /// The widget that renders [identity]'s shared screen, live.
  ///
  /// Returned as a plain [Widget] so no LiveKit type crosses the package
  /// seam; the real rendering is [ScreenShareView], which tracks the room's
  /// events itself so a share track arriving a beat after the roster flips
  /// still appears. Out of a call it renders nothing, not a placeholder:
  /// there is no room to watch.
  Widget screenShareViewFor(String identity) {
    final room = _room;
    if (room == null) return const SizedBox.shrink();
    return ScreenShareView(
      room: room,
      identity: identity,
      density: _receiveDensity,
    );
  }

  /// Per tile key (`<kind>:<identity>`), what each remote video's tile should
  /// say beyond its picture: paused by the server, stalled and recovering, or
  /// stopped. A tile missing from the map is playing normally.
  ValueListenable<Map<String, VideoTileHealth>> get videoHealth =>
      _stallWatchdog.health;

  /// The widget that renders [identity]'s live camera feed, [screenShareViewFor]'s
  /// exact counterpart: a plain [Widget] backed by [CameraView], working for
  /// the local participant exactly as it works for anyone else, which is
  /// what makes a self camera preview possible.
  Widget cameraViewFor(String identity) {
    final room = _room;
    if (room == null) return const SizedBox.shrink();
    return CameraView(
      room: room,
      identity: identity,
      facing: _cameraSwitching.facing,
      density: _receiveDensity,
    );
  }

  /// Declares which presence tiles currently want video, by the same
  /// `'<kind>:<identity>'` key the canvas already keys a tile with, so a
  /// remote video track nothing is showing can be unsubscribed outright
  /// rather than only paused; see [VideoSubscriptionCuller] for the timing
  /// and for why audio is never in scope. Null means this caller has no
  /// opinion and every track should stay subscribed, which is what a surface
  /// says when it unmounts or when it cannot speak for the call at all.
  void setVideoInterest(Set<String>? tileKeys) {
    _videoCuller.setInterest(tileKeys);
    _applyVideoInterest();
  }

  /// Keeps the screen-share (or camera) tiles named by [tileKeys] unsubscribed
  /// whatever the interest says, along with a share's own audio, so a viewer
  /// who stopped watching pays no bandwidth or decode for it.
  void setVideoBlocked(Set<String> tileKeys) {
    _videoCuller.setBlocked(tileKeys);
    _applyVideoInterest();
  }

  /// Whether flipping needs no chosen device; see [CameraSwitching.canFlip].
  bool get canFlipCamera => _cameraSwitching.canFlip;

  /// Whether picking a camera needs one named first; see
  /// [CameraSwitching.needsSelection].
  bool get cameraNeedsSelection => _cameraSwitching.needsSelection;

  /// The cameras this desktop (or browser) offers, for the picker. Calling
  /// this is what makes a later [selectCameraDevice] able to find anything,
  /// the same reason [screenShareSources] has to run first.
  Future<List<CameraDevice>> cameraDevices() =>
      _reported('list cameras', const [], _cameraSwitching.devices);

  /// Flips the published camera between front and back, mobile only.
  Future<bool> flipCamera() => _reported(
        'switch the camera',
        false,
        () => _cameraSwitching.flip(_room?.localParticipant),
      );

  /// Switches the published camera to [device], desktop's answer to
  /// [flipCamera] where more than one webcam can exist.
  Future<bool> selectCameraDevice(CameraDevice device) async {
    final room = _room;
    if (room == null) return false;
    return _reported('choose the camera', false, () async {
      await _cameraSwitching.select(room, device);
      _refreshParticipants();
      return true;
    });
  }

  /// Runs [run]; a failure is reported, kept as [lastError], and answered
  /// with [fallback] so a picker or toggle never throws into the UI.
  Future<T> _reported<T>(
    String action,
    T fallback,
    Future<T> Function() run,
  ) async {
    try {
      return await run();
    } catch (e, stack) {
      reportFailure(LogTag.voice, action, e, stack);
      _lastError = e;
      return fallback;
    }
  }

  @override
  void _refreshParticipants() => _rebuildRoster();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _videoCuller.dispose();
    _receiveDensity.dispose();
    await _stallStats?.cancel();
    _stallWatchdog.dispose();
    await callStats.dispose();
    health.dispose();
    _joinTimings.finish();
    // After `_teardown`, or its own `resetFacing()` writes past disposal.
    await _teardown();
    _cameraSwitching.dispose();
    await _disposeCapture();
    await _disposeMicRecovery();
    await _gate.dispose();
    await _stateController.close();
    await _participantsController.close();
  }
}
