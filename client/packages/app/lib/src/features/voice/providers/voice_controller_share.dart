// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Screen sharing's start/stop outcome handling and the broadcast deadline,
/// split out for [VoiceController]'s own 500-line hard ceiling once the
/// share-audio toggle pushed it over; `voice_controller_input.dart`'s own
/// mixin-in-a-part shape, for the identical reason its doc comment states.
mixin VoiceControllerShareMixin on StateNotifier<VoiceState> {
  /// Bridges to [VoiceController]'s own members, abstract here because the
  /// `on` clause, not shared-library privacy, bounds the implicit receiver.
  VoiceSession get _shareSession;
  void _log(String message, {Object? detail});
  bool get supportsScreenShareAudio;
  Duration get broadcastStartTimeout;

  Timer? _broadcastDeadline;

  Future<void> setScreenShare(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async {
    _cancelBroadcastDeadline();
    final outcome = await _shareSession.setScreenShareEnabled(
      enabled,
      quality: quality,
      sourceId: sourceId,
      // Defended here too, not only in the UI: a settings value can outlive a platform switch.
      includeAudio: includeAudio && supportsScreenShareAudio,
      maxHeight: maxHeight,
    );
    switch (outcome) {
      case ScreenShareOutcome.started:
        state = state.copyWith(screenSharing: true, clearError: true);
      case ScreenShareOutcome.stopped:
        state = state.copyWith(screenSharing: false, clearError: true);
      case ScreenShareOutcome.pendingBroadcast:
        state = state.copyWith(awaitingBroadcast: true, clearError: true);
        _broadcastDeadline = Timer(
          broadcastStartTimeout,
          _reportBroadcastNeverStarted,
        );
      case ScreenShareOutcome.unsupported:
        state = state.copyWith(
          screenSharing: false,
          awaitingBroadcast: false,
          error:
              'This build cannot share a screen: its screen recording '
              'extension is missing or not set up.',
          retryable: false,
        );
      case ScreenShareOutcome.failed:
        final cause = _shareSession.lastError;
        _log(
          'Screen share ${enabled ? 'start' : 'stop'} failed',
          detail: cause,
        );
        state = state.copyWith(
          screenSharing: false,
          awaitingBroadcast: false,
          // Cause included, not dropped: the bare sentence once hid a real Linux failure.
          error: enabled
              ? 'Could not start sharing. ${cause ?? 'The system refused the capture.'}'
              : 'Could not stop sharing. ${cause ?? ''}'.trim(),
        );
    }
  }

  /// The user was shown a broadcast picker and nothing came of it: they
  /// dismissed it, or there was nothing in it to pick. Either way the share
  /// is not happening, and saying nothing would leave the button pretending.
  void _reportBroadcastNeverStarted() {
    _broadcastDeadline = null;
    if (!state.awaitingBroadcast) return;
    state = state.copyWith(
      awaitingBroadcast: false,
      screenSharing: false,
      error:
          'Screen sharing never started. Tap share again and choose Start '
          'Broadcast. If nothing appeared to choose, this build has no screen '
          'recording extension.',
    );
  }

  void _cancelBroadcastDeadline() {
    _broadcastDeadline?.cancel();
    _broadcastDeadline = null;
  }
}
