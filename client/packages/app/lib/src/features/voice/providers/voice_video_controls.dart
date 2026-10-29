// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';

import '../widgets/video_health_overlay.dart';
import 'voice_camera_failure.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

/// Video tiles and camera selection.
class VoiceVideoControls {
  VoiceVideoControls(this._session, this._access, this._callGeneration);

  final VoiceSession _session;
  final VoiceStateAccess _access;

  /// The owning controller's call generation; see `VoiceController.join`.
  final int Function() _callGeneration;

  VoiceState get _current => _access.state;

  /// Whether starting a share here needs a screen chosen first, and the
  /// screens to choose from. Enumerating is also what makes the capture that
  /// follows able to find anything, so it happens even for a single screen.
  bool get screenShareNeedsSource => _session.screenShareNeedsSource;

  /// See [VoiceSession.screenShareSourcePickerUseful].
  bool get screenShareSourcePickerUseful =>
      _session.screenShareSourcePickerUseful;

  Future<List<ScreenShareSource>> screenShareSources() =>
      _session.screenShareSources();

  /// [identity]'s shared screen; see [VoiceSession.screenShareViewFor].
  Widget screenShareViewFor(String identity, {bool declaresInterest = true}) =>
      voiceVideoView(
        participants: _current.participants,
        health: _session.videoHealth,
        identity: identity,
        view: _session.screenShareViewFor(identity),
        screenShare: true,
        declaresInterest: declaresInterest,
      );

  /// [identity]'s camera feed; see [VoiceSession.cameraViewFor].
  Widget cameraViewFor(String identity, {bool declaresInterest = true}) =>
      voiceVideoView(
        participants: _current.participants,
        health: _session.videoHealth,
        identity: identity,
        view: _session.cameraViewFor(identity),
        screenShare: false,
        declaresInterest: declaresInterest,
      );

  /// Declares which presence tiles a surface currently wants video for, so
  /// the rest can be unsubscribed; see [VoiceSession.setVideoInterest].
  /// Null hands the decision back, and is what a surface says on unmount.
  void setVideoInterest(Set<String>? tileKeys) =>
      _session.setVideoInterest(tileKeys);

  /// Keeps one tile sharp while it is fullscreen or popped out, even under
  /// Data saver; call the result when it shrinks again.
  VoidCallback holdEnlargedVideo(String tileKey) =>
      _session.holdEnlargedVideo(tileKey);

  /// Whether switching cameras is a bare flip (mobile) rather than a picker.
  bool get canFlipCamera => _session.canFlipCamera;

  /// Whether switching cameras needs one named first (desktop and web).
  bool get cameraNeedsSelection => _session.cameraNeedsSelection;

  /// The cameras available to pick from; see [VoiceSession.cameraDevices].
  Future<List<CameraDevice>> cameraDevices() => _session.cameraDevices();

  /// Flips the published camera between front and back, mobile only.
  Future<bool> flipCamera() async {
    final ok = await _session.flipCamera();
    _access.state = _current.copyWith(
      error: ok ? null : 'Could not switch the camera.',
      clearError: ok,
    );
    return ok;
  }

  /// Switches the published camera to [device], desktop's picker equivalent
  /// of [flipCamera].
  Future<bool> selectCameraDevice(CameraDevice device) async {
    final ok = await _session.selectCameraDevice(device);
    _access.state = _current.copyWith(
      error: ok ? null : 'Could not switch to that camera.',
      clearError: ok,
    );
    return ok;
  }

  /// Turns a live camera off and on again so a new quality takes effect;
  /// the device, mute and hidden choices live outside the track and carry over.
  Future<void> restartCamera() async {
    final connected = _current.state == VoiceSessionState.connected;
    if (!connected || !_current.cameraEnabled || _current.cameraPending) return;
    final generation = _callGeneration();
    _access.state = _current.copyWith(cameraPending: true);
    final (off, offCause) = await setCameraWithin(_session, false);
    final (on, onCause) = off && generation == _callGeneration()
        ? await setCameraWithin(_session, true)
        : (false, null);
    if (generation != _callGeneration()) {
      if (_current.cameraPending) {
        _access.state = _current.copyWith(cameraPending: false);
      }
      return;
    }
    final failed = !off || !on;
    _access.state = _current.copyWith(
      cameraPending: false,
      cameraEnabled: !off ? _current.cameraEnabled : on,
      error: failed
          ? cameraFailureMessage(off, off ? onCause : offCause)
          : null,
      clearError: !failed,
    );
  }

  /// Starts or stops publishing the camera without touching the user's choice
  /// of device; the roster repaint reports the result.
  Future<bool> setCameraPublishing(bool on) async =>
      (await setCameraWithin(_session, on)).$1;
}
