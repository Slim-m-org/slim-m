// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:slimm_rtc/rtc.dart';

import 'call_foreground_keeper.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

/// Screen sharing's start/stop outcome handling and the broadcast deadline.
class VoiceScreenShare {
  VoiceScreenShare(
    this._session,
    this._foreground,
    this._access,
    this._log, {
    required this.broadcastStartTimeout,
  });

  final VoiceSession _session;
  final CallForegroundKeeper _foreground;
  final VoiceStateAccess _access;
  final void Function(String message, {Object? detail}) _log;

  /// How long to wait for iOS to actually start a broadcast before saying so.
  /// Long enough for the picker, its confirmation and a three second
  /// countdown; short enough that a build with no extension is not a mystery.
  final Duration broadcastStartTimeout;

  VoiceState get _current => _access.state;

  /// Whether this host can publish a screen share's own audio. True on web
  /// and Linux; see `screen_share_audio.dart` in the rtc package for why the
  /// rest cannot, or in Linux's case can only conditionally.
  bool get supportsAudio => _session.supportsScreenShareAudio;

  Timer? _broadcastDeadline;

  /// The screen the last share was started on, kept so a quality change can
  /// restart it without asking again.
  String? lastShareSourceId;

  /// What the running share captures; the screen overlay needs to know a window from a screen.
  ScreenShareSource? lastShareSource;

  /// Whether a share can be stopped and started again with no picker or
  /// permission prompt: only where this app lists the sources itself and the
  /// choice is its own (Windows, macOS), never Wayland, web or mobile.
  bool get screenShareRestartable =>
      _session.screenShareNeedsSource && _session.screenShareSourcePickerUseful;

  Future<void> setScreenShare(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
    ScreenShareSource? source,
  }) async {
    cancelBroadcastDeadline();
    if (enabled && sourceId != null) lastShareSourceId = sourceId;
    lastShareSource = enabled ? source : null;
    if (enabled && !await _foreground.beforeShare()) {
      _foreground.shareSettled(started: false);
      _access.state = _current.copyWith(
        screenSharing: false,
        error: 'Screen sharing needs permission to capture the screen.',
        retryable: true,
      );
      return;
    }
    final outcome = await _session.setScreenShareEnabled(
      enabled,
      quality: quality,
      sourceId: sourceId,
      // Defended here too, not only in the UI: a settings value can outlive a platform switch.
      includeAudio: includeAudio && supportsAudio,
      maxHeight: maxHeight,
    );
    _foreground.shareSettled(started: outcome == ScreenShareOutcome.started);
    switch (outcome) {
      case ScreenShareOutcome.started:
        _access.state = _current.copyWith(
          screenSharing: true,
          shareAudio: shareAudioNow(),
          clearError: true,
        );
      case ScreenShareOutcome.stopped:
        _access.state = _current.copyWith(
          screenSharing: false,
          shareAudio: ShareAudio.none,
          clearError: true,
        );
      case ScreenShareOutcome.pendingBroadcast:
        _access.state = _current.copyWith(
          awaitingBroadcast: true,
          clearError: true,
        );
        _broadcastDeadline = Timer(
          broadcastStartTimeout,
          _reportBroadcastNeverStarted,
        );
      case ScreenShareOutcome.unsupported:
        _access.state = _current.copyWith(
          screenSharing: false,
          awaitingBroadcast: false,
          error:
              'This build cannot share a screen: its screen recording '
              'extension is missing or not set up.',
          retryable: false,
        );
      case ScreenShareOutcome.failed:
        final cause = _session.lastError;
        _log(
          'Could not ${enabled ? 'start' : 'stop'} the screen share',
          detail: cause,
        );
        _access.state = _current.copyWith(
          screenSharing: false,
          awaitingBroadcast: false,
          // Cause included, not dropped: the bare sentence once hid a real Linux failure.
          error: enabled
              ? 'Could not start sharing. ${cause ?? 'The system refused the capture.'}'
              : 'Could not stop sharing. ${cause ?? ''}'.trim(),
        );
    }
  }

  /// The shared window or screen went away; the session already ended the share.
  void reportShareSourceLost() {
    _log('The shared window or screen is gone; sharing stopped');
    _access.state = _current.copyWith(
      screenSharing: false,
      shareAudio: ShareAudio.none,
      error: 'The window you were sharing closed, so sharing stopped.',
    );
  }

  ShareAudio shareAudioNow() {
    if (!_session.screenShareHasAudio) return ShareAudio.none;
    return _session.screenShareAudioMuted ? ShareAudio.muted : ShareAudio.on;
  }

  /// Silences or restores the running share's audio without ending the share.
  Future<void> setScreenShareAudioOn(bool on) async {
    if (_current.shareAudio == ShareAudio.none) return;
    final done = await _session.setScreenShareAudioMuted(!on);
    if (!done) {
      _log('Could not switch the shared audio', detail: _session.lastError);
      return;
    }
    _access.state = _current.copyWith(
      shareAudio: on ? ShareAudio.on : ShareAudio.muted,
    );
  }

  /// The user was shown a broadcast picker and nothing came of it: they
  /// dismissed it, or there was nothing in it to pick. Either way the share
  /// is not happening, and saying nothing would leave the button pretending.
  void _reportBroadcastNeverStarted() {
    _broadcastDeadline = null;
    if (!_current.awaitingBroadcast) return;
    _access.state = _current.copyWith(
      awaitingBroadcast: false,
      screenSharing: false,
      error:
          'Screen sharing never started. Tap share again and choose Start '
          'Broadcast. If nothing appeared to choose, this build has no screen '
          'recording extension.',
    );
  }

  void cancelBroadcastDeadline() {
    _broadcastDeadline?.cancel();
    _broadcastDeadline = null;
  }
}
