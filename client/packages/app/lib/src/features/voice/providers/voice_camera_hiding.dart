// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import 'voice_state_access.dart';

const _hiddenCamerasKey = 'slimm.voice.hidden_cameras';

/// People whose camera this listener chose not to watch, remembered per person.
///
/// A hidden camera is unsubscribed like a hidden share, and the roster the UI
/// sees reports it as off, so every surface shows the avatar tile instead.
class VoiceCameraHiding {
  VoiceCameraHiding(this._session, this._ref, this._access);

  final VoiceSession _session;
  final Ref _ref;
  final VoiceStateAccess _access;

  Set<String> _hiddenCameras = const {};
  Set<String> _shareBlocked = const {};

  bool isCameraHidden(String identity) => _hiddenCameras.contains(identity);

  List<VoiceParticipant> _rawRoster = const [];

  /// The roster as the UI sees it: hidden cameras read as off.
  List<VoiceParticipant> shownRoster(List<VoiceParticipant> roster) {
    _rawRoster = roster;
    if (_hiddenCameras.isEmpty) return roster;
    return [
      for (final p in roster)
        if (p.isCameraOn && !p.isLocal && _hiddenCameras.contains(p.identity))
          p.copyWith(isCameraOn: false)
        else
          p,
    ];
  }

  /// Stops (or resumes) receiving [identity]'s camera; remembered across calls.
  Future<void> setCameraHidden(String identity, bool hidden) async {
    if (hidden == _hiddenCameras.contains(identity)) return;
    _hiddenCameras = hidden
        ? {..._hiddenCameras, identity}
        : ({..._hiddenCameras}..remove(identity));
    pushBlocked();
    _access.state = _access.state.copyWith(
      participants: shownRoster(_rawRoster),
    );
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setStringList(_hiddenCamerasKey, _hiddenCameras.toList());
  }

  /// Keeps these screen shares unsubscribed whatever the interest says; see [VoiceSession.setVideoBlocked].
  void setVideoBlocked(Set<String> tileKeys) {
    _shareBlocked = tileKeys;
    pushBlocked();
  }

  void pushBlocked() => _session.setVideoBlocked({
    ..._shareBlocked,
    for (final id in _hiddenCameras)
      videoSubscriptionKey(identity: id, screenShare: false),
  });

  Future<void> restoreHiddenCameras() async {
    final prefs = await _ref.read(preferencesProvider.future);
    _hiddenCameras = (prefs.getStringList(_hiddenCamerasKey) ?? const [])
        .toSet();
    pushBlocked();
  }
}
