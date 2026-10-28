// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which running share [ShareRecovery] watches, and how it repeats that share.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'screen_share.dart';
import 'screen_share_local.dart';
import 'screen_share_recovery.dart';

/// Starts or stops the share described by the request and reports how it went.
typedef ApplyShare = Future<ScreenShareOutcome> Function(
  bool enabled,
  ShareRequest request,
);

class ScreenShareWatch {
  ScreenShareWatch({
    required lk.LocalParticipant? Function() participant,
    required ApplyShare apply,
    bool Function()? isWindows,
  })  : _apply = apply,
        _isWindows =
            isWindows ?? (() => lk.lkPlatformIs(lk.PlatformType.windows)) {
    _recovery = ShareRecovery(
      read: () => readLocalShare(participant()),
      pause: (paused) => pauseLocalShare(participant(), paused),
      restart: _restart,
    );
  }

  final ApplyShare _apply;
  final bool Function() _isWindows;
  late final ShareRecovery _recovery;
  final _windowSourceIds = <String>{};
  ShareRequest? _request;

  void noteSources(List<ScreenShareSource> sources) => _windowSourceIds
    ..clear()
    ..addAll([for (final s in sources.where((s) => s.isWindow)) s.id]);

  /// Only Windows window capture is known to go silent without an error.
  void watch(ShareRequest request, ScreenShareOutcome outcome) {
    if (outcome != ScreenShareOutcome.started || !_isWindows()) return;
    _request = request;
    _recovery.start(windowShare: _windowSourceIds.contains(request.sourceId));
  }

  void stop() => _recovery.stop();

  Future<void> _restart() async {
    final request = _request;
    if (request == null) return;
    await _apply(false, request);
    final outcome = await _apply(true, request);
    if (outcome != ScreenShareOutcome.started) {
      throw StateError('the share did not restart: $outcome');
    }
  }
}
