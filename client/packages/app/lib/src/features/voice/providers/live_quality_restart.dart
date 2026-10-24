// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Restarts a live screen share or camera when its quality setting changes.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart' show apiProvider;
import 'screen_share_ceiling.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

/// How long a burst of changes settles before the restart, so dragging
/// through options restarts once with the final value.
const liveQualityRestartDelay = Duration(milliseconds: 700);

/// What a settings row says while the running share cannot restart itself.
const shareSettingsPendingNote = 'Applies the next time you share.';

/// True while a running share could not pick up a changed setting by itself.
final shareSettingsPendingProvider = StateProvider<bool>((ref) => false);

class LiveQualityRestart {
  LiveQualityRestart(this._ref, {Duration delay = liveQualityRestartDelay})
    : _delay = delay {
    _ref.listen(
      voiceSettingsControllerProvider.select(
        (s) => (s.screenShareQuality.id, s.screenShareIncludeAudio),
      ),
      (_, _) => _scheduleShare(),
    );
    _ref.listen(
      voiceSettingsControllerProvider.select((s) => s.cameraQuality),
      (_, _) => _scheduleCamera(),
    );
    _ref.listen(voiceControllerProvider.select((s) => s.screenSharing), (
      _,
      sharing,
    ) {
      if (sharing) return;
      _ref.read(shareSettingsPendingProvider.notifier).state = false;
    });
    _ref.onDispose(() {
      _shareTimer?.cancel();
      _cameraTimer?.cancel();
    });
  }

  final Ref _ref;
  final Duration _delay;
  Timer? _shareTimer;
  Timer? _cameraTimer;
  bool _restartingShare = false;
  bool _restartingCamera = false;

  void _scheduleShare() {
    _shareTimer?.cancel();
    _shareTimer = Timer(_delay, () => unawaited(_restartShare()));
  }

  void _scheduleCamera() {
    _cameraTimer?.cancel();
    _cameraTimer = Timer(_delay, () => unawaited(_restartCamera()));
  }

  Future<void> _restartShare() async {
    final controller = _ref.read(voiceControllerProvider.notifier);
    if (!_ref.read(voiceControllerProvider).screenSharing) return;
    final pending = _ref.read(shareSettingsPendingProvider.notifier);
    if (!controller.screenShareRestartable) {
      pending.state = true;
      return;
    }
    if (_restartingShare) {
      _scheduleShare();
      return;
    }
    _restartingShare = true;
    try {
      final sourceId = await _reusableSource(controller);
      if (sourceId == null ||
          !_ref.read(voiceControllerProvider).screenSharing) {
        pending.state = sourceId == null;
        return;
      }
      pending.state = false;
      final settings = _ref.read(voiceSettingsControllerProvider);
      final maxHeight = await screenShareCeilingFrom(_ref.read(apiProvider));
      await controller.setScreenShare(false);
      await controller.setScreenShare(
        true,
        quality: settings.screenShareQuality,
        sourceId: sourceId,
        includeAudio: settings.screenShareIncludeAudio,
        maxHeight: maxHeight,
      );
    } finally {
      _restartingShare = false;
    }
  }

  /// The screen the share is on, if it is still listed; null when it is gone.
  Future<String?> _reusableSource(VoiceController controller) async {
    final sources = await controller.screenShareSources();
    final last = controller.lastShareSourceId;
    if (last != null && sources.any((s) => s.id == last)) return last;
    return sources.length == 1 ? sources.first.id : null;
  }

  Future<void> _restartCamera() async {
    if (_restartingCamera) {
      _scheduleCamera();
      return;
    }
    _restartingCamera = true;
    try {
      await _ref.read(voiceControllerProvider.notifier).restartCamera();
    } finally {
      _restartingCamera = false;
    }
  }
}

/// Watched from the signed-in shell so it lives for the session.
final liveQualityRestartProvider = Provider<LiveQualityRestart>(
  (ref) => LiveQualityRestart(ref),
);
