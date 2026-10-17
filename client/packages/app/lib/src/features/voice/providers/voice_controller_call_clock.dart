// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Moving [VoiceState.connectedAt] back to the call's real start once the
/// server has said when that was.
///
/// Split out for [VoiceController]'s own 500-line hard ceiling, as a mixin
/// for the reason [VoiceControllerInputMixin] gives.
mixin VoiceControllerCallClockMixin on StateNotifier<VoiceState> {
  VoiceCallClock get _callClock;

  /// Only ever earlier than what is shown: a participant leaving must not move the timer back up.
  Future<void> _adoptServerCallStart() async {
    final channelId = state.channelId;
    if (channelId == null || state.connectedAt == null) return;
    final start = await _callClock.serverStart(channelId);
    final shown = state.connectedAt;
    if (start == null || state.channelId != channelId || shown == null) return;
    if (start.isBefore(shown)) state = state.copyWith(connectedAt: start);
  }
}
