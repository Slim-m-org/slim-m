// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives the one voice call this client can be in.
///
/// One call at a time, deliberately. Joining a second channel leaves the first
/// rather than holding two open microphones, which is what a user means by
/// "join" and is also the only behaviour the call controls can describe.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../push/providers/push_channel_providers.dart';
import 'call_foreground_keeper.dart';
import 'call_recap.dart';
import 'join_timings_provider.dart';
import 'level_display.dart';
import 'mic_failure_advice.dart';
import 'voice_audio_devices.dart';
import 'voice_auto_rejoin.dart';
import 'voice_call_clock.dart';
import 'voice_call_heartbeat.dart';
import 'voice_camera_failure.dart';
import 'voice_camera_hiding.dart';
import 'voice_camera_preference.dart';
import 'voice_input_settings.dart';
import 'voice_join_muted.dart';
import 'voice_participant_volumes.dart';
import 'voice_rejoin.dart';
import 'voice_screen_share.dart';
import 'voice_settings_controller.dart' show loadCameraOnJoinPreference;
import 'voice_session_sync.dart';
import 'voice_sfu_connect.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';
import 'voice_video_controls.dart';

export 'voice_input_settings.dart'
    show kSpaceNoiseSuppressionRecheck, spaceNoiseSuppressionRecheck;
export 'voice_state.dart' show VoiceState;

class VoiceController extends StateNotifier<VoiceState> {
  VoiceController(
    this._ref, {
    VoiceSession? session,
    CallLifecycleChannel? callLifecycle,
    CallForegroundKeeper? foreground,
    Duration broadcastStartTimeout = const Duration(seconds: 30),
    Duration voiceHeartbeatInterval = const Duration(seconds: 15),
    List<Duration> autoRejoinDelays = VoiceAutoRejoin.defaultDelays,
    DateTime Function()? now,
  }) : _session =
           session ??
           VoiceSession(
             joinTimings: _ref.read(joinTimingsProvider),
             audioLog: (line, {level = api.LogLevel.info}) =>
                 api.AppLog.at(level, api.LogTag.voice, line),
           ),
       _callLifecycle = callLifecycle ?? CallLifecycleChannel(),
       _foreground =
           foreground ??
           CallForegroundKeeper(
             requestNotifications: () async {
               await _ref.read(localNotificationsProvider).requestPermission();
             },
           ),
       _heartbeat = VoiceCallHeartbeat(
         _ref,
         interval: voiceHeartbeatInterval,
         now: now,
       ),
       _autoRejoin = VoiceAutoRejoin(delays: autoRejoinDelays),
       _callClock = VoiceCallClock(_ref, now: now),
       _now = now ?? DateTime.now,
       _activity = CallActivityTracker(now: now ?? DateTime.now),
       super(const VoiceState()) {
    final access = VoiceStateAccess(read: () => state, write: (s) => state = s);
    input = VoiceInputSettings(_session, _ref, access);
    devices = VoiceAudioDevices(_session, _ref, access);
    volumes = VoiceParticipantVolumes(_session, _ref, _log);
    cameras = VoiceCameraHiding(_session, _ref, access);
    video = VoiceVideoControls(_session, access, () => _callGeneration);
    share = VoiceScreenShare(
      _session,
      _foreground,
      access,
      _log,
      broadcastStartTimeout: broadcastStartTimeout,
    );
    _rejoin = VoiceRejoin(access, _autoRejoin, _callClock, _ref, join);
    _sfu = VoiceSfuConnect(_session, _ref, access, _joinMuted, input);
    _sync = VoiceSessionSync(
      session: _session,
      access: access,
      callLifecycle: _callLifecycle,
      foreground: _foreground,
      heartbeat: _heartbeat,
      autoRejoin: _autoRejoin,
      callClock: _callClock,
      rejoin: _rejoin,
      input: input,
      cameras: cameras,
      log: _log,
    );
    _endCallRequests = _callLifecycle.endCallRequests.listen((_) {
      unawaited(leave());
    });
    listenLevelDisplayed(_ref, _session.setLevelDisplayed);
    _states = _session.states.listen(_sync.onSessionState);
    _shareSourceLost = _session.screenShareSourceLost.listen(
      (_) => share.reportShareSourceLost(),
    );
    _participants = _session.participantChanges.listen((p) {
      _activity.observe(p);
      unawaited(_callClock.adoptServerStart(access));
      // Trust the session's view of the local participant over the local
      // toggle: the SFU is what actually decides whether a track is live.
      final sharing = p.any((x) => x.isLocal && x.isScreenSharing);
      final camera = p.any((x) => x.isLocal && x.isCameraOn);
      if (sharing) share.cancelBroadcastDeadline();
      _foreground.media(camera: camera, sharing: sharing);
      state = state.copyWith(
        participants: cameras.shownRoster(p),
        screenSharing: sharing,
        shareAudio: sharing ? share.shareAudioNow() : ShareAudio.none,
        cameraEnabled: camera,
        awaitingBroadcast: sharing ? false : state.awaitingBroadcast,
      );
    });
  }

  final Ref _ref;
  final VoiceSession _session;

  /// The microphone, noise suppression, input gate and video quality choices.
  late final VoiceInputSettings input;

  /// Microphone and speaker selection, and the microphone's own health.
  late final VoiceAudioDevices devices;

  /// Per-participant playback volume.
  late final VoiceParticipantVolumes volumes;

  /// Whose camera this listener chose not to watch.
  late final VoiceCameraHiding cameras;

  /// Video tiles and camera selection.
  late final VoiceVideoControls video;

  /// Screen sharing and the broadcast deadline.
  late final VoiceScreenShare share;
  late final VoiceRejoin _rejoin;
  late final VoiceSfuConnect _sfu;
  late final VoiceSessionSync _sync;

  final CallLifecycleChannel _callLifecycle;
  final CallForegroundKeeper _foreground;
  final VoiceCallHeartbeat _heartbeat;
  final VoiceAutoRejoin _autoRejoin;
  final VoiceCallClock _callClock;
  final VoiceJoinMuted _joinMuted = VoiceJoinMuted();
  final VoiceCameraPreference _cameraPreference = VoiceCameraPreference();
  final DateTime Function() _now;
  final CallActivityTracker _activity;
  late final StreamSubscription<VoiceSessionState> _states;
  late final StreamSubscription<List<VoiceParticipant>> _participants;
  late final StreamSubscription<String> _shareSourceLost;
  late final StreamSubscription<void> _endCallRequests;

  /// Bumped by every [join] and [leave], so a stale call's continuation can tell it was superseded.
  int _callGeneration = 0;

  /// Changes whenever a call starts or ends, for work that must not outlive its call.
  int get callGeneration => _callGeneration;

  /// Sets the camera preference before joining; use [toggleCamera] in a call.
  void setCameraPreference(bool enabled) =>
      state = _cameraPreference.apply(state, enabled);

  /// Seeds [setCameraPreference] from the saved setting, awaited once from bootstrap.
  Future<void> restoreCameraPreference() async {
    setCameraPreference(await loadCameraOnJoinPreference(_ref));
  }

  /// [join] with the mic off for this call, whatever the saved preference;
  /// the idle pane's "Join muted".
  Future<void> joinMuted(String channelId) {
    _muteNextJoin = true;
    return join(channelId);
  }

  bool _muteNextJoin = false;

  /// A channel switch (or a [leave]) mid-join starts or ends a newer call on
  /// this same instance, so every write below is guarded by [superseded]:
  /// reproduced without it, an abandoned join's belated failure landed as
  /// the *current* (different) channel's error, hiding a call that had
  /// actually connected - see `voice_controller_join_race_test.dart`.
  Future<void> join(String channelId) async {
    final mutedByCaller = _muteNextJoin;
    _muteNextJoin = false;
    // A recap belongs to the call that just ended, never to this new one.
    _activity.reset();
    // A queued rejoin was about the call this one replaces; see VoiceAutoRejoin.cancelPending.
    _autoRejoin.cancelPending();
    unawaited(input.refreshSpaceNoiseSuppression());
    // See this method's own doc comment for what generation/superseded guard.
    final generation = ++_callGeneration;
    bool superseded() => generation != _callGeneration;
    _ref.read(joinTimingsProvider).begin();
    // Set before the first await, so an arrival elsewhere reads this as busy (VoiceState.joining); clearJustLeft because any real join attempt is never a stale rejoin to suppress.
    state = state.copyWith(
      channelId: channelId,
      microphoneEnabled: _joinMuted.preferenceAtJoin(state.microphoneEnabled),
      clearError: true,
      clearRecap: true,
      joining: true,
      rejoining: _rejoin.autoAttemptChannel == channelId,
      clearJustLeft: true,
    );
    await _sfu.run(channelId, mutedByCaller, superseded);
  }

  /// Supersedes any in-flight [join], and is superseded the same way: a leave
  /// overtaken by a newer call writes nothing (see docs/internals.md, voice call generations).
  Future<void> leave() async {
    final generation = ++_callGeneration;
    share.cancelBroadcastDeadline();
    final channelId = state.channelId;
    final startedAt = state.connectedAt;
    // Read before `_session.leave()`, so nobody still here misreads as having left when we did.
    final recap = channelId != null && startedAt != null
        ? _activity.summary(
            channelId: channelId,
            startedAt: startedAt,
            endedAt: _now(),
          )
        : null;
    _heartbeat.stop();
    input.stopWatchingSpaceNoiseSuppression();
    _autoRejoin.reset();
    _callClock.forget();
    _ref.read(joinTimingsProvider).finish();
    await _session.leave();
    if (generation != _callGeneration) return;
    // Best-effort and fire-and-forget: this client already disconnected.
    if (channelId != null) unawaited(_heartbeat.forget(channelId));
    // The mic/camera preference survives the reset (no lobby left to re-set them on); justLeftChannelId/justLeftAt are set only here, see VoiceState.rejoinGuardWindow.
    state = VoiceState(
      microphoneEnabled: _joinMuted.preferenceAtLeave(state.microphoneEnabled),
      cameraEnabled: _cameraPreference.atLeave(state.cameraEnabled),
      recap: recap,
      justLeftChannelId: channelId,
      justLeftAt: channelId == null ? null : _now(),
    );
  }

  /// Guarded by the call generation like [join] and [leave]: the SFU round
  /// trip can outlive the call it was asked in, and its answer belongs to
  /// that call, not to whichever one is connected by the time it lands.
  Future<void> toggleMicrophone() async {
    final generation = _callGeneration;
    final want = !state.microphoneEnabled;
    final got = await _session.setMicrophoneEnabled(want);
    if (generation != _callGeneration) return;
    // Reflects what happened rather than what was asked for, so the button
    // never claims a microphone is open when the SFU refused the track.
    final error = got
        ? null
        : micRefusalError(_micVerb(want), devices.micFailure);
    state = state.copyWith(
      microphoneEnabled: got ? want : state.microphoneEnabled,
      error: error,
      clearError: error == null,
    );
  }

  static String _micVerb(bool want) => want ? 'unmute' : 'mute';

  static String _deafenVerb(bool want) => want ? 'deafen' : 'undeafen';

  /// Enables or disables the local camera mid-call, [toggleMicrophone]'s
  /// exact counterpart. The participant listener above corrects this from
  /// the session's own truth regardless, so a refusal here still repaints
  /// as off rather than lying that the toggle worked.
  ///
  /// The cause is included and logged rather than dropped, [setScreenShare]'s
  /// own reasoning: a bare "could not turn the camera on" gives whoever hits
  /// this nothing to act on. [cameraFailureMessage] says the specific thing
  /// where the platform actually distinguished it, and the raw cause
  /// otherwise, rather than inventing a distinction it did not give us.
  Future<void> toggleCamera() async {
    if (state.cameraPending) return;
    final generation = _callGeneration;
    final want = !state.cameraEnabled;
    state = state.copyWith(cameraPending: true);
    final (got, cause) = await setCameraWithin(_session, want);
    if (generation != _callGeneration) return;
    if (cause != null) {
      _log('Could not turn the camera ${want ? 'on' : 'off'}', detail: cause);
    }
    state = state.copyWith(
      cameraPending: false,
      cameraEnabled: got ? want : state.cameraEnabled,
      error: got ? null : cameraFailureMessage(want, cause),
      clearError: got,
    );
  }

  /// Whether [identity] is silenced for this listener alone; see
  /// [VoiceSession.setLocallyMuted].
  bool isLocallyMuted(String identity) => _session.isLocallyMuted(identity);

  /// Silences (or restores) one participant locally. Rebuilds the state so a
  /// popover reading [isLocallyMuted] repaints with the new label.
  Future<void> setLocallyMuted(String identity, bool muted) async {
    await _session.setLocallyMuted(identity, muted);
    state = state.copyWith(
      participants: cameras.shownRoster(_session.participants),
    );
  }

  /// Per-person audio quality and the last call's summary.
  VoiceHealth get health => _session.health;

  /// Live per-track video numbers; sampled only while something listens.
  CallStatsSampler get callStats => _session.callStats;

  /// Toggles local playback of everyone else's audio; independent of muting.
  Future<void> toggleDeafen() async {
    final generation = _callGeneration;
    final want = !state.deafened;
    final got = await _session.setDeafened(want);
    if (generation != _callGeneration) return;
    if (got) unawaited(devices.publishDeafenedState(want));
    state = state.copyWith(
      deafened: got ? want : state.deafened,
      error: got ? null : 'Could not ${_deafenVerb(want)}.',
      clearError: got,
    );
  }

  /// [identity]'s camera feed; the canvas draws it too, so it stays here.
  Widget cameraViewFor(String identity, {bool declaresInterest = true}) =>
      video.cameraViewFor(identity, declaresInterest: declaresInterest);

  /// [identity]'s shared screen; see [cameraViewFor].
  Widget screenShareViewFor(String identity, {bool declaresInterest = true}) =>
      video.screenShareViewFor(identity, declaresInterest: declaresInterest);

  void _log(
    String message, {
    Object? detail,
    api.LogLevel level = api.LogLevel.warning,
  }) => api.AppLog.at(level, api.LogTag.voice, message, error: detail);

  @override
  void dispose() {
    share.cancelBroadcastDeadline();
    volumes.dispose();
    _heartbeat.stop();
    input.stopWatchingSpaceNoiseSuppression();
    _autoRejoin.reset();
    unawaited(_states.cancel());
    unawaited(_participants.cancel());
    unawaited(_shareSourceLost.cancel());
    unawaited(_endCallRequests.cancel());
    unawaited(_session.dispose());
    _callLifecycle.dispose();
    super.dispose();
  }
}

final voiceControllerProvider =
    StateNotifierProvider<VoiceController, VoiceState>(
      (ref) => VoiceController(ref),
    );
