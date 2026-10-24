// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Video tiles and camera selection, split out of [VoiceController] for the
/// file budget; the same mixin-in-a-part shape as `voice_controller_share.dart`.
mixin VoiceControllerVideoMixin on StateNotifier<VoiceState> {
  VoiceSession get _videoSession;

  /// Whether starting a share here needs a screen chosen first, and the
  /// screens to choose from. Enumerating is also what makes the capture that
  /// follows able to find anything, so it happens even for a single screen.
  bool get screenShareNeedsSource => _videoSession.screenShareNeedsSource;

  /// See [VoiceSession.screenShareSourcePickerUseful].
  bool get screenShareSourcePickerUseful =>
      _videoSession.screenShareSourcePickerUseful;

  Future<List<ScreenShareSource>> screenShareSources() =>
      _videoSession.screenShareSources();

  /// [identity]'s shared screen; see [VoiceSession.screenShareViewFor].
  Widget screenShareViewFor(String identity, {bool declaresInterest = true}) =>
      voiceVideoView(
        participants: state.participants,
        health: _videoSession.videoHealth,
        identity: identity,
        view: _videoSession.screenShareViewFor(identity),
        screenShare: true,
        declaresInterest: declaresInterest,
      );

  /// [identity]'s camera feed; see [VoiceSession.cameraViewFor].
  Widget cameraViewFor(String identity, {bool declaresInterest = true}) =>
      voiceVideoView(
        participants: state.participants,
        health: _videoSession.videoHealth,
        identity: identity,
        view: _videoSession.cameraViewFor(identity),
        screenShare: false,
        declaresInterest: declaresInterest,
      );

  /// Declares which presence tiles a surface currently wants video for, so
  /// the rest can be unsubscribed; see [VoiceSession.setVideoInterest].
  /// Null hands the decision back, and is what a surface says on unmount.
  void setVideoInterest(Set<String>? tileKeys) =>
      _videoSession.setVideoInterest(tileKeys);

  /// Whether switching cameras is a bare flip (mobile) rather than a picker.
  bool get canFlipCamera => _videoSession.canFlipCamera;

  /// Whether switching cameras needs one named first (desktop and web).
  bool get cameraNeedsSelection => _videoSession.cameraNeedsSelection;

  /// The cameras available to pick from; see [VoiceSession.cameraDevices].
  Future<List<CameraDevice>> cameraDevices() => _videoSession.cameraDevices();

  /// Flips the published camera between front and back, mobile only.
  Future<bool> flipCamera() async {
    final ok = await _videoSession.flipCamera();
    state = state.copyWith(
      error: ok ? null : 'Could not switch the camera.',
      clearError: ok,
    );
    return ok;
  }

  /// Switches the published camera to [device], desktop's picker equivalent
  /// of [flipCamera].
  Future<bool> selectCameraDevice(CameraDevice device) async {
    final ok = await _videoSession.selectCameraDevice(device);
    state = state.copyWith(
      error: ok ? null : 'Could not switch to that camera.',
      clearError: ok,
    );
    return ok;
  }

  /// Turns a live camera off and on again so a new quality takes effect;
  /// the device, mute and hidden choices live outside the track and carry over.
  Future<void> restartCamera() async {
    if (!state.cameraEnabled || state.cameraPending) return;
    final channelId = state.channelId;
    state = state.copyWith(cameraPending: true);
    final (off, offCause) = await setCameraWithin(_videoSession, false);
    final (on, onCause) = off
        ? await setCameraWithin(_videoSession, true)
        : (false, null);
    if (state.channelId != channelId) return;
    final failed = !off || !on;
    state = state.copyWith(
      cameraPending: false,
      cameraEnabled: !off ? state.cameraEnabled : on,
      error: failed
          ? cameraFailureMessage(off, off ? onCause : offCause)
          : null,
    );
  }
}
