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

import '../../../api_failure.dart';
import 'call_recap.dart';
import 'level_display.dart';
import 'noise_suppression.dart';
import '../../../providers/providers.dart';
import 'voice_auto_rejoin.dart';
import 'voice_call_clock.dart';
import 'voice_call_heartbeat.dart';
import 'voice_call_lifecycle_report.dart';
import 'mic_failure_advice.dart';
import 'voice_camera_failure.dart';
import 'voice_deafen_publish.dart';
import 'voice_camera_preference.dart';
import 'voice_join_muted.dart';
import '../widgets/video_health_overlay.dart';
import 'voice_participant_volume_store.dart';
import 'volume_drag_throttle.dart';
import 'voice_settings_controller.dart';
import 'voice_sfu_security.dart';
import 'voice_state.dart';

export 'voice_state.dart' show VoiceState;

part 'voice_controller_audio_devices.dart';
part 'voice_controller_call_clock.dart';
part 'voice_controller_camera_hide.dart';
part 'voice_controller_input.dart';
part 'voice_controller_participant_volume.dart';
part 'voice_controller_rejoin.dart';
part 'voice_controller_share.dart';
part 'voice_controller_video.dart';

class VoiceController extends StateNotifier<VoiceState>
    with
        VoiceControllerInputMixin,
        VoiceControllerCallClockMixin,
        VoiceControllerRejoinMixin,
        VoiceControllerShareMixin,
        VoiceControllerAudioDevicesMixin,
        VoiceControllerParticipantVolumeMixin,
        VoiceControllerCameraHideMixin,
        VoiceControllerVideoMixin {
  VoiceController(
    this._ref, {
    VoiceSession? session,
    CallLifecycleChannel? callLifecycle,
    this.broadcastStartTimeout = const Duration(seconds: 30),
    Duration voiceHeartbeatInterval = const Duration(seconds: 15),
    List<Duration> autoRejoinDelays = VoiceAutoRejoin.defaultDelays,
    DateTime Function()? now,
  }) : _session =
           session ??
           VoiceSession(
             audioLog: (line, {level = api.LogLevel.info}) =>
                 api.AppLog.at(level, api.LogTag.voice, line),
           ),
       _callLifecycle = callLifecycle ?? CallLifecycleChannel(),
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
    _endCallRequests = _callLifecycle.endCallRequests.listen((_) {
      unawaited(leave());
    });
    listenLevelDisplayed(_ref, _session.setLevelDisplayed);
    _states = _session.states.listen(_onSessionState);
    _participants = _session.participantChanges.listen((p) {
      _activity.observe(p);
      unawaited(_adoptServerCallStart());
      // Trust the session's view of the local participant over the local
      // toggle: the SFU is what actually decides whether a track is live.
      final sharing = p.any((x) => x.isLocal && x.isScreenSharing);
      final camera = p.any((x) => x.isLocal && x.isCameraOn);
      if (sharing) _cancelBroadcastDeadline();
      state = state.copyWith(
        participants: _shownRoster(p),
        screenSharing: sharing,
        cameraEnabled: camera,
        awaitingBroadcast: sharing ? false : state.awaitingBroadcast,
      );
    });
  }

  /// How long to wait for iOS to actually start a broadcast before saying so.
  /// Long enough for the picker, its confirmation and a three second
  /// countdown; short enough that a build with no extension is not a mystery.
  @override
  final Duration broadcastStartTimeout;

  final Ref _ref;
  final VoiceSession _session;

  /// [VoiceControllerInputMixin]'s own required bridge to the fields above.
  @override
  VoiceSession get _inputSession => _session;
  @override
  VoiceAutoRejoin get _rejoinAttempts => _autoRejoin;
  @override
  Ref get _inputRef => _ref;

  final CallLifecycleChannel _callLifecycle;
  final VoiceCallHeartbeat _heartbeat;
  final VoiceAutoRejoin _autoRejoin;
  @override
  final VoiceCallClock _callClock;
  final VoiceJoinMuted _joinMuted = VoiceJoinMuted();
  final VoiceCameraPreference _cameraPreference = VoiceCameraPreference();
  final DateTime Function() _now;
  final CallActivityTracker _activity;
  late final StreamSubscription<VoiceSessionState> _states;
  late final StreamSubscription<List<VoiceParticipant>> _participants;
  late final StreamSubscription<void> _endCallRequests;

  /// Bumped by every [join] and [leave], so a stale call's continuation can
  /// tell it has been superseded; see [join]'s own comment on why this
  /// exists.
  int _callGeneration = 0;

  /// Sets the camera preference before joining; use [toggleCamera] for the
  /// live in-call control. Its microphone sibling died with the join lobby
  /// (d190a711) and was deleted rather than left as an uncalled method.
  void setCameraPreference(bool enabled) =>
      state = _cameraPreference.apply(state, enabled);

  /// Seeds [setCameraPreference] from the persisted setting Voice Settings
  /// writes, for the one moment [join]'s own preference-carrying (see
  /// [leave]) has nothing yet to carry: a fresh app launch's first call.
  ///
  /// Explicit and awaited once from bootstrap, `ThemeController.restore`'s
  /// own shape, rather than read from this constructor: a constructor read
  /// would make every existing test building a bare [VoiceController]
  /// depend on mocked shared preferences it has no reason to set up.
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

  void _onSessionState(VoiceSessionState s) {
    reportCallLifecycle(_callLifecycle, s, channelId: state.channelId);
    final dropped = _classifiedDisconnect();
    if (s == VoiceSessionState.failed && dropped != null) {
      _heartbeat.stop();
      _log('The call ended: ${dropped.name}', detail: dropped.message);
      _endCallForDrop(dropped);
      return;
    }
    _syncHeartbeat(s);
    // The clock starts at the connected transition only; see VoiceCallClock.
    state = switch (s) {
      VoiceSessionState.connected when state.connectedAt == null =>
        state.copyWith(state: s, connectedAt: _callClock.beginHere()),
      VoiceSessionState.idle || VoiceSessionState.failed => state.copyWith(
        state: s,
        clearConnectedAt: true,
      ),
      _ => state.copyWith(state: s),
    };
    if (s == VoiceSessionState.connected) {
      _pushBlocked();
      unawaited(_adoptServerCallStart());
    }
  }

  /// A drop the SFU decided on: the reason is the only thing that can tell
  /// "you joined elsewhere" from "your network went". A `removed` that
  /// arrives while this client's own heartbeat has been failing is far
  /// more likely the server's stale-heartbeat sweep than a moderator.
  VoiceDisconnect? _classifiedDisconnect() {
    final raw = _session.lastDisconnect;
    final lagging = raw == VoiceDisconnect.removed && _heartbeat.isLagging;
    return lagging ? VoiceDisconnect.heartbeatLagEviction : raw;
  }

  void _syncHeartbeat(VoiceSessionState s) {
    switch (s) {
      case VoiceSessionState.connected:
        // Not gated on lifecycle: only termination may let this lapse.
        _heartbeat.start(state.channelId);
        _autoRejoin.connected();
        if (state.rejoining) state = state.copyWith(rejoining: false);
      case VoiceSessionState.idle:
      case VoiceSessionState.failed:
        _heartbeat.stop();
      default:
        break;
    }
  }

  /// A channel switch (or a [leave]) mid-join starts or ends a newer call on
  /// this same instance, so every write below is guarded by [superseded]:
  /// reproduced without it, an abandoned join's belated failure landed as
  /// the *current* (different) channel's error, hiding a call that had
  /// actually connected - see `voice_controller_join_race_test.dart`.
  @override
  Future<void> join(String channelId) async {
    final mutedByCaller = _muteNextJoin;
    _muteNextJoin = false;
    // A recap belongs to the call that just ended, never to this new one.
    _activity.reset();
    // A queued rejoin was about the call this one replaces; see VoiceAutoRejoin.cancelPending.
    _autoRejoin.cancelPending();
    unawaited(refreshSpaceNoiseSuppression());
    // See this method's own doc comment for what generation/superseded guard.
    final generation = ++_callGeneration;
    bool superseded() => generation != _callGeneration;
    // Set before the first await, so an arrival elsewhere reads this as busy (VoiceState.joining); clearJustLeft because any real join attempt is never a stale rejoin to suppress.
    state = state.copyWith(
      channelId: channelId,
      microphoneEnabled: _joinMuted.preferenceAtJoin(state.microphoneEnabled),
      clearError: true,
      clearRecap: true,
      joining: true,
      rejoining: _autoAttemptChannel == channelId,
      clearJustLeft: true,
    );
    try {
      await _connect(channelId, mutedByCaller, superseded);
    } on api.NotConfiguredException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'This server has no voice set up',
        error,
        stack,
      );
      _failJoin(superseded, 'This Space has no voice configured.');
    } on api.ForbiddenException catch (error, stack) {
      api.reportFailure(api.LogTag.voice, 'join the call', error, stack);
      _failJoin(superseded, 'You do not have permission to join this channel.');
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.voice, 'join the call', e, stack);
      _failJoin(
        superseded,
        describeApiFailure('join the call', e),
        retryable: true,
      );
    } catch (e) {
      // Joining is automatic now, so nothing asks first; an exception no other clause names must still fail cleanly.
      if (!superseded()) {
        _log('Could not join the call', detail: e, level: api.LogLevel.error);
      }
      _failJoin(superseded, 'Could not join the call.', retryable: true);
    } finally {
      if (!superseded()) state = state.copyWith(joining: false);
    }
  }

  Future<void> _connect(
    String channelId,
    bool mutedByCaller,
    bool Function() superseded,
  ) async {
    final token = await _ref.read(apiProvider).voiceToken(channelId);
    final mutedByChannel = await _joinMuted.asksFor(_ref, channelId);
    if (superseded()) return;
    final insecureReason = insecureSfuReason(token.url);
    if (insecureReason != null) {
      state = state.copyWith(
        state: VoiceSessionState.failed,
        error: insecureReason,
        retryable: false,
      );
      return;
    }
    state = state.copyWith(canPublish: token.canPublish);
    if (mutedByChannel || mutedByCaller) state = _joinMuted.showMuted(state);
    // Push-to-talk joins closed: it opens only while the key is held; see setPushToTalkPreference.
    final microphoneAtJoin =
        state.microphoneEnabled && token.canPublish && !_pushToTalkEnabled;
    await _session.join(
      url: token.url,
      token: token.token,
      // Asking for a microphone or camera a token cannot publish just
      // produces a failure to report; not asking is the honest thing.
      microphoneEnabled: microphoneAtJoin,
      cameraEnabled: state.cameraEnabled && token.canPublish,
    );
    if (superseded()) return;
    // Show the push-to-talk-closed mic in the button; scoped to PTT so the canPublish path is untouched.
    if (_pushToTalkEnabled && state.microphoneEnabled) {
      state = state.copyWith(microphoneEnabled: false);
    }
    if (_session.state == VoiceSessionState.failed) {
      state = state.copyWith(
        error: 'Could not connect to the call. ${_session.lastError ?? ''}'
            .trim(),
      );
    }
  }

  void _failJoin(
    bool Function() superseded,
    String error, {
    bool retryable = false,
  }) {
    if (superseded()) return;
    state = state.copyWith(
      state: VoiceSessionState.failed,
      error: error,
      retryable: retryable,
    );
  }

  /// Also supersedes any in-flight [join]; see its own doc comment.
  ///
  /// And is superseded the same way, which is what the guard past the await
  /// below is for: tearing a session down is a real round trip to the SFU
  /// and nothing in the UI waits on it, so somebody who hangs up and taps a
  /// channel again straight away can have a newer call already connected by
  /// the time this resumes. Everything after that point belongs to the newer
  /// call, so a superseded leave writes nothing at all - not the reset,
  /// which left a live call with no [VoiceState.channelId] for every voice
  /// surface to read as "not in this call", and not the heartbeat forget,
  /// which the server turns into a hangup it broadcasts to everyone else.
  /// The heartbeat entry the abandoned call leaves behind is exactly what
  /// `voice/heartbeat.rs`'s staleness sweep exists to collect.
  Future<void> leave() async {
    final generation = ++_callGeneration;
    _cancelBroadcastDeadline();
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
    _autoRejoin.reset();
    _callClock.forget();
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
    final error = got ? null : micRefusalError(_micVerb(want), micFailure);
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
    state = state.copyWith(participants: _shownRoster(_session.participants));
  }

  /// Whether this host can publish a screen share's own audio. True on web
  /// and Linux; see `screen_share_audio.dart` in the rtc package for why the
  /// rest cannot, or in Linux's case can only conditionally.
  @override
  bool get supportsScreenShareAudio => _session.supportsScreenShareAudio;

  /// Live per-track video numbers; sampled only while something listens.
  CallStatsSampler get callStats => _session.callStats;

  /// Toggles local playback of everyone else's audio; independent of muting.
  Future<void> toggleDeafen() async {
    final generation = _callGeneration;
    final want = !state.deafened;
    final got = await _session.setDeafened(want);
    if (generation != _callGeneration) return;
    if (got) unawaited(publishDeafenedState(want));
    state = state.copyWith(
      deafened: got ? want : state.deafened,
      error: got ? null : 'Could not ${_deafenVerb(want)}.',
      clearError: got,
    );
  }

  @override
  VoiceSession get _shareSession => _session;

  @override
  VoiceSession get _videoSession => _session;

  @override
  void _log(
    String message, {
    Object? detail,
    api.LogLevel level = api.LogLevel.warning,
  }) => api.AppLog.at(level, api.LogTag.voice, message, error: detail);

  @override
  void dispose() {
    _cancelBroadcastDeadline();
    _heartbeat.stop();
    _autoRejoin.reset();
    unawaited(_states.cancel());
    unawaited(_participants.cancel());
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
