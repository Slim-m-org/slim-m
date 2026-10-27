// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// The screen share's self-repair, split out for [VoiceSession]'s 500-line ceiling like its siblings.
extension VoiceSessionShareRecovery on VoiceSession {
  void _noteWindowSources(List<ScreenShareSource> sources) => _windowSourceIds
    ..clear()
    ..addAll([for (final s in sources.where((s) => s.isWindow)) s.id]);

  /// Only Windows window capture is known to go silent without an error.
  void _watchShare(ShareRequest request, ScreenShareOutcome outcome) {
    if (outcome != ScreenShareOutcome.started) return;
    if (!lk.lkPlatformIs(lk.PlatformType.windows)) return;
    _shareRequest = request;
    _shareRecovery.start(
      windowShare: _windowSourceIds.contains(request.sourceId),
    );
  }

  /// Stops and starts the share again on the source it was started with.
  Future<void> _restartShare() async {
    final request = _shareRequest;
    if (request == null) return;
    await _applyScreenShare(false, request);
    final outcome = await _applyScreenShare(true, request);
    if (outcome != ScreenShareOutcome.started) {
      throw StateError('the share did not restart: $outcome');
    }
  }
}
