// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a viewer's direct play is doing, for the controller and the panel.
library;

import 'direct_play_eligibility.dart';

enum DirectPlayPhase { off, signIn, connecting, playing }

class DirectPlayState {
  const DirectPlayState({
    this.phase = DirectPlayPhase.off,
    this.enabled = false,
    this.block,
    this.notice,
    this.signInError,
    this.localPause,
    this.checking = false,
  });

  final DirectPlayPhase phase;

  /// The viewer's saved choice; it stays on across a fall back so the next party tries again.
  final bool enabled;
  final DirectPlayBlock? block;

  /// Why the viewer is back on the shared stream after trying, until they act.
  final String? notice;
  final String? signInError;

  /// Where the room is while this viewer is paused on their own.
  final Duration? localPause;
  final bool checking;

  bool get active =>
      phase == DirectPlayPhase.connecting || phase == DirectPlayPhase.playing;

  DirectPlayState copyWith({
    DirectPlayPhase? phase,
    bool? enabled,
    Object? block = _keep,
    Object? notice = _keep,
    Object? signInError = _keep,
    Object? localPause = _keep,
    bool? checking,
  }) => DirectPlayState(
    phase: phase ?? this.phase,
    enabled: enabled ?? this.enabled,
    block: identical(block, _keep) ? this.block : block as DirectPlayBlock?,
    notice: identical(notice, _keep) ? this.notice : notice as String?,
    signInError: identical(signInError, _keep)
        ? this.signInError
        : signInError as String?,
    localPause: identical(localPause, _keep)
        ? this.localPause
        : localPause as Duration?,
    checking: checking ?? this.checking,
  );
}

const Object _keep = Object();
