// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

const _hiddenCamerasKey = 'slimm.voice.hidden_cameras';

/// People whose camera this listener chose not to watch, remembered per person.
///
/// A hidden camera is unsubscribed like a hidden share, and the roster the UI
/// sees reports it as off, so every surface shows the avatar tile instead.
mixin VoiceControllerCameraHideMixin on StateNotifier<VoiceState> {
  VoiceSession get _inputSession;
  Ref get _inputRef;

  Set<String> _hiddenCameras = const {};
  Set<String> _shareBlocked = const {};

  bool isCameraHidden(String identity) => _hiddenCameras.contains(identity);

  List<VoiceParticipant> _rawRoster = const [];

  /// The roster as the UI sees it: hidden cameras read as off.
  List<VoiceParticipant> _shownRoster(List<VoiceParticipant> roster) {
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
    _pushBlocked();
    state = state.copyWith(participants: _shownRoster(_rawRoster));
    final prefs = await _inputRef.read(preferencesProvider.future);
    await prefs.setStringList(_hiddenCamerasKey, _hiddenCameras.toList());
  }

  /// Keeps these screen shares unsubscribed whatever the interest says; see [VoiceSession.setVideoBlocked].
  void setVideoBlocked(Set<String> tileKeys) {
    _shareBlocked = tileKeys;
    _pushBlocked();
  }

  void _pushBlocked() => _inputSession.setVideoBlocked({
    ..._shareBlocked,
    for (final id in _hiddenCameras)
      videoSubscriptionKey(identity: id, screenShare: false),
  });

  Future<void> restoreHiddenCameras() async {
    final prefs = await _inputRef.read(preferencesProvider.future);
    _hiddenCameras = (prefs.getStringList(_hiddenCamerasKey) ?? const [])
        .toSet();
    _pushBlocked();
  }
}
