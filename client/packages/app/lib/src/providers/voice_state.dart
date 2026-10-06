// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything a voice surface needs to render, in one value.
///
/// Split out of `voice_controller.dart`, which sat at this repo's 500-line
/// hard ceiling before the camera-refusal diagnostics grew it past it.
library;

import 'package:slimm_rtc/rtc.dart';

import 'call_recap.dart';
import 'voice_auto_rejoin.dart';

class VoiceState {
  const VoiceState({
    this.channelId,
    this.state = VoiceSessionState.idle,
    this.joining = false,
    this.rejoining = false,
    this.participants = const [],
    this.microphoneEnabled = true,
    this.cameraEnabled = false,
    this.cameraPending = false,
    this.screenSharing = false,
    this.awaitingBroadcast = false,
    this.canPublish = true,
    this.deafened = false,
    this.error,
    this.retryable = true,
    this.connectedAt,
    this.recap,
    this.justLeftChannelId,
    this.justLeftAt,
  });

  /// How long [justLeftChannelId] keeps suppressing an automatic rejoin after
  /// [VoiceController.leave].
  ///
  /// Long enough to cover `home_shell.dart`'s canvas-pane swap, which
  /// destroys and remounts `VoiceScreen` (a fresh `State`, so its own
  /// `_autoJoinedFor` guard is blank) well within a second of the tap that
  /// triggered it; short enough that a caller who instead leaves, moves on,
  /// and comes back to the same channel minutes later still gets the normal
  /// one-tap auto-join rather than a stale "you left" screen. This is a
  /// belt-and-braces window, not the whole guard: `voice_screen.dart` also
  /// latches its own `_autoJoinedFor` the first time this window is read as
  /// still open, so a widget that stays mounted past [rejoinGuardWindow]
  /// keeps reading as "already attempted" rather than flipping back to an
  /// automatic join once the clock runs out from under it.
  static const rejoinGuardWindow = Duration(seconds: 5);

  /// The channel this call belongs to, so a screen can tell "in a call here"
  /// from "in a call somewhere else".
  final String? channelId;
  final VoiceSessionState state;
  final List<VoiceParticipant> participants;

  /// True for the whole span of a [VoiceController.join] call, set before
  /// its first `await` and cleared in a `finally`. [state] does not reach
  /// [VoiceSessionState.connecting] until the token round trip already
  /// answered, so this is what tells a screen arriving elsewhere that a
  /// join is under way during that gap; see `voice_screen.dart`'s `_busyElsewhere`.
  final bool joining;

  /// True while an automatic rejoin is waiting to run after the network took
  /// the call: see [VoiceAutoRejoin]. Distinct from [joining], which covers
  /// an attempt actually in flight, because the gap between two attempts is
  /// still time the app spends reconnecting and a screen that read it as
  /// "you left" would be showing an error nobody had been asked to act on.
  final bool rejoining;

  /// What the user has asked for, which is not always what they got: a token
  /// without SPEAK cannot open a microphone however the toggle is set.
  final bool microphoneEnabled;

  /// What the user has asked for, the same double duty [microphoneEnabled]
  /// carries: a pre-toggle before `VoiceController.join`, and the live truth
  /// once in a call, kept in step by `VoiceController`'s participant listener.
  final bool cameraEnabled;

  /// A camera toggle is under way: opening a webcam can take seconds, and a
  /// second press then would race the first.
  final bool cameraPending;
  final bool screenSharing;

  /// iOS only: sharing has been asked for and the system is waiting on the
  /// user to start a broadcast. Nobody can see a screen yet, so this is
  /// deliberately not [screenSharing]; showing it as sharing is the exact
  /// lie this field exists to stop.
  final bool awaitingBroadcast;

  /// Whether the token allows publishing at all, mirroring the SPEAK grant.
  final bool canPublish;

  /// Whether every other participant's audio is locally silenced. Purely
  /// local: it never touches this session's own microphone, so it carries
  /// no [canPublish]-style server permission to check.
  final bool deafened;

  final String? error;

  /// False for a failure this channel cannot retry its way out of: no voice
  /// configured, or no permission. True (the default) is everything
  /// transient, where trying again might really work.
  final bool retryable;

  /// When this call connected, for the in-call duration readout. Null
  /// whenever not connected; survives reconnect-free state churn but resets
  /// with the call.
  final DateTime? connectedAt;

  /// The most recently finished call in this channel, shown once on the
  /// screen a hang-up leaves you on; see `CallRecap`'s own doc comment.
  /// Cleared by the next `VoiceController.join`, whichever channel it
  /// targets, so it never survives to be shown for the wrong call.
  final CallRecap? recap;

  /// The channel an explicit [VoiceController.leave] just walked away from,
  /// so a `VoiceScreen` remounted by the canvas-pane swap can tell "the user
  /// just hung up" from "this is a fresh arrival" even though its own
  /// per-widget memory of having joined was destroyed along with it. See
  /// [rejoinGuardWindow] for how long this keeps mattering, and
  /// [VoiceController.join] for where it is cleared again.
  final String? justLeftChannelId;

  /// When [justLeftChannelId] was recorded, so a reader can tell whether
  /// [rejoinGuardWindow] has already passed.
  final DateTime? justLeftAt;

  VoiceState copyWith({
    String? channelId,
    VoiceSessionState? state,
    bool? joining,
    bool? rejoining,
    List<VoiceParticipant>? participants,
    bool? microphoneEnabled,
    bool? cameraEnabled,
    bool? cameraPending,
    bool? screenSharing,
    bool? awaitingBroadcast,
    bool? canPublish,
    bool? deafened,
    String? error,
    bool clearError = false,
    bool? retryable,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
    CallRecap? recap,
    bool clearRecap = false,
    String? justLeftChannelId,
    DateTime? justLeftAt,
    bool clearJustLeft = false,
  }) => VoiceState(
    channelId: channelId ?? this.channelId,
    state: state ?? this.state,
    joining: joining ?? this.joining,
    rejoining: rejoining ?? this.rejoining,
    participants: participants ?? this.participants,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    cameraPending: cameraPending ?? this.cameraPending,
    screenSharing: screenSharing ?? this.screenSharing,
    awaitingBroadcast: awaitingBroadcast ?? this.awaitingBroadcast,
    canPublish: canPublish ?? this.canPublish,
    deafened: deafened ?? this.deafened,
    error: clearError ? null : (error ?? this.error),
    retryable: clearError ? true : (retryable ?? this.retryable),
    connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
    recap: clearRecap ? null : (recap ?? this.recap),
    justLeftChannelId: clearJustLeft
        ? null
        : (justLeftChannelId ?? this.justLeftChannelId),
    justLeftAt: clearJustLeft ? null : (justLeftAt ?? this.justLeftAt),
  );
}
