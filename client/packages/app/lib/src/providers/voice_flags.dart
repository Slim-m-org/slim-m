// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The low-churn half of [VoiceState]: everything except
/// [VoiceState.participants].
///
/// `voiceControllerProvider` bundles a call's roster - which changes on
/// every join, leave, mute and speaking flicker - together with fields like
/// [VoiceFlags.cameraEnabled], [VoiceFlags.deafened] and [VoiceFlags.error]
/// that change rarely by comparison. A widget that only cares about the
/// latter used to rebuild on the former anyway, since both lived in one
/// `ref.watch(voiceControllerProvider)`.
///
/// [voiceFlagsProvider] and [voiceParticipantsProvider] are the split: each
/// forwards a `select` over the same underlying [VoiceController], so a
/// watcher of one is never notified by a change that only touches the other.
/// A helper that draws mic/camera/deafen controls should take a [VoiceFlags]
/// rather than a [VoiceState] - that way its signature makes it impossible to
/// thread the roster through by accident.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'call_recap.dart';
import 'voice_controller.dart';

class VoiceFlags {
  const VoiceFlags({
    this.channelId,
    this.state = VoiceSessionState.idle,
    this.joining = false,
    this.rejoining = false,
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

  factory VoiceFlags.from(VoiceState state) => VoiceFlags(
    channelId: state.channelId,
    state: state.state,
    joining: state.joining,
    rejoining: state.rejoining,
    microphoneEnabled: state.microphoneEnabled,
    cameraEnabled: state.cameraEnabled,
    cameraPending: state.cameraPending,
    screenSharing: state.screenSharing,
    awaitingBroadcast: state.awaitingBroadcast,
    canPublish: state.canPublish,
    deafened: state.deafened,
    error: state.error,
    retryable: state.retryable,
    connectedAt: state.connectedAt,
    recap: state.recap,
    justLeftChannelId: state.justLeftChannelId,
    justLeftAt: state.justLeftAt,
  );

  /// Whether the call controls belong on screen for [channel]: connected
  /// there, or inside its bounded auto-rejoin, where the call is still ours
  /// to mute or leave. One rule for the voice stage and the canvas dock, so
  /// they cannot disagree about whether a call is up.
  bool inCallStageFor(String channel) =>
      channelId == channel &&
      (state == VoiceSessionState.connected || rejoining);

  final String? channelId;
  final VoiceSessionState state;
  final bool joining;

  /// See [VoiceState.rejoining].
  final bool rejoining;
  final bool microphoneEnabled;
  final bool cameraEnabled;

  /// See [VoiceState.cameraPending].
  final bool cameraPending;
  final bool screenSharing;
  final bool awaitingBroadcast;
  final bool canPublish;
  final bool deafened;
  final String? error;
  final bool retryable;
  final DateTime? connectedAt;
  final CallRecap? recap;
  final String? justLeftChannelId;
  final DateTime? justLeftAt;

  @override
  bool operator ==(Object other) =>
      other is VoiceFlags &&
      other.channelId == channelId &&
      other.state == state &&
      other.joining == joining &&
      other.rejoining == rejoining &&
      other.microphoneEnabled == microphoneEnabled &&
      other.cameraEnabled == cameraEnabled &&
      other.cameraPending == cameraPending &&
      other.screenSharing == screenSharing &&
      other.awaitingBroadcast == awaitingBroadcast &&
      other.canPublish == canPublish &&
      other.deafened == deafened &&
      other.error == error &&
      other.retryable == retryable &&
      other.connectedAt == connectedAt &&
      other.recap == recap &&
      other.justLeftChannelId == justLeftChannelId &&
      other.justLeftAt == justLeftAt;

  @override
  int get hashCode => Object.hash(
    channelId,
    state,
    joining,
    rejoining,
    microphoneEnabled,
    cameraEnabled,
    cameraPending,
    screenSharing,
    awaitingBroadcast,
    canPublish,
    deafened,
    error,
    retryable,
    connectedAt,
    recap,
    Object.hash(justLeftChannelId, justLeftAt),
  );
}

/// The low-churn slice of [voiceControllerProvider]: mic, camera, deafen,
/// share, error and the rest of [VoiceState] minus the roster. A watcher only
/// rebuilds when one of these fields actually changes, so a join, leave,
/// mute or speaking flicker on [voiceParticipantsProvider] never reaches it.
final voiceFlagsProvider = Provider<VoiceFlags>(
  (ref) => ref.watch(voiceControllerProvider.select(VoiceFlags.from)),
);

/// The high-churn slice of [voiceControllerProvider]: the live roster alone.
/// A watcher rebuilds on every join, leave, mute or speaking change - exactly
/// the noise [voiceFlagsProvider] exists to shield everything else from.
final voiceParticipantsProvider = Provider<List<VoiceParticipant>>(
  (ref) => ref.watch(voiceControllerProvider.select((s) => s.participants)),
);
