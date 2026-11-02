// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Putting a screen share back, or saying it is gone, after a dropped call rejoins.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart' show apiProvider;
import 'screen_share_ceiling.dart';
import 'voice_screen_share.dart';
import 'voice_settings_controller.dart';
import 'voice_state_access.dart';

/// What the call says when it cannot put a dropped share back by itself.
const shareEndedByDropNotice =
    'Your screen share ended when the call dropped - share again';

class VoiceShareResume {
  VoiceShareResume({
    required Ref ref,
    required VoiceSession session,
    required VoiceScreenShare share,
    required VoiceStateAccess access,
    required int Function() callGeneration,
  }) : _ref = ref,
       _session = session,
       _share = share,
       _access = access,
       _callGeneration = callGeneration;

  final Ref _ref;
  final VoiceSession _session;
  final VoiceScreenShare _share;
  final VoiceStateAccess _access;
  final int Function() _callGeneration;

  bool _owed = false;

  /// Remembers a share a drop ended; call it before the dropped call's state is rewritten.
  void noteDrop({required bool wasSharing}) => _owed = wasSharing;

  /// Forgets it, for a hang-up or another channel, which are decisions rather than drops.
  void forget() => _owed = false;

  /// Settles a remembered share once the call is back: restarts it where no prompt is needed, otherwise says it ended.
  Future<void> onConnected() async {
    if (!_owed) return;
    _owed = false;
    final generation = _callGeneration();
    bool sameCall() =>
        generation == _callGeneration() &&
        _access.state.state == VoiceSessionState.connected;
    final sourceId = _share.screenShareRestartable
        ? _share.lastShareSourceId
        : null;
    if (sourceId != null) {
      final sources = await _session.screenShareSources();
      if (!sameCall()) return;
      if (sources.any((s) => s.id == sourceId)) {
        await _restart(sourceId, sameCall);
        return;
      }
    }
    _access.state = _access.state.copyWith(error: shareEndedByDropNotice);
  }

  Future<void> _restart(String sourceId, bool Function() sameCall) async {
    final settings = _ref.read(voiceSettingsControllerProvider);
    final maxHeight = await screenShareCeilingFrom(_ref.read(apiProvider));
    if (!sameCall()) return;
    await _share.setScreenShare(
      true,
      source: _share.lastShareSource,
      quality: settings.screenShareQuality,
      sourceId: sourceId,
      includeAudio: settings.screenShareIncludeAudio,
      maxHeight: maxHeight,
    );
  }
}
