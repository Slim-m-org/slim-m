// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera half of a voice session: toggle, picker, join-time open and view.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'camera_devices.dart';
import 'camera_join.dart';
import 'camera_switching.dart';
import 'camera_view.dart';
import 'video_quality.dart';
import 'voice_models.dart';
import 'voice_session_screen_share.dart';

/// Lists, flips, selects and toggles cameras on the session's room, and renders them.
class VoiceCamera {
  VoiceCamera(
    this._host,
    this._density, {
    CameraDevices? devices,
    Duration joinTimeout = kJoinCameraTimeout,
  })  : switching = CameraSwitching(devices ?? const HardwareCameraDevices()),
        _join = CameraJoin(timeout: joinTimeout);

  final VoiceScreenShareHost _host;
  final CameraSwitching switching;
  final ValueListenable<lk.AdaptiveStreamPixelDensity> _density;
  final CameraJoin _join;

  /// How sharp the camera publishes. Read when the camera turns on, and a
  /// different one than it was published at republishes; the app cycles a live
  /// camera to apply a change.
  CameraQuality quality = CameraQuality.balanced;

  /// The webcam picked in an earlier call; opened instead of the default while it is still plugged in.
  String? preferredDeviceId;

  /// The camera a join asked for opens after "connected"; this reports its start, failure and end.
  Stream<CameraJoinOpen> get joinOpens => _join.events;

  Future<List<CameraDevice>> devices() =>
      _host.reported('list cameras', const [], switching.devices);

  Future<bool> flip() => _host.reported(
        'switch the camera',
        false,
        () => switching.flip(_host.room()?.localParticipant),
      );

  Future<bool> select(CameraDevice device) async {
    final room = _host.room();
    if (room == null) return false;
    return _host.reported('choose the camera', false, () async {
      await switching.select(room, device);
      preferredDeviceId = device.id;
      _host.refresh();
      return true;
    });
  }

  /// Publishes (or stops) a camera track. Failure is swallowed, as the
  /// microphone's is: a camera pre-toggle a device cannot honour (permission
  /// denied, no hardware) must not fail the join, since a call with no camera
  /// track is still a call.
  Future<bool> trySetEnabled(bool enabled) async {
    final room = _host.room();
    if (room == null) return false;
    final result = await _setEnabled(room, enabled);
    final error = result.error;
    if (error != null) _host.noteError(error);
    return result.ok;
  }

  /// The saved webcam's id when this platform picks by id and it is still present, else null.
  Future<String?> _presentPreferredId() async {
    final wanted = preferredDeviceId;
    if (wanted == null || !switching.needsSelection) return null;
    final present = await devices();
    return present.any((d) => d.id == wanted) ? wanted : null;
  }

  Future<CameraToggleResult> _setEnabled(lk.Room room, bool enabled) async {
    final saved = enabled && preferredDeviceId != null
        ? await _presentPreferredId()
        : null;
    final base = cameraCaptureOptionsFor(
      room.roomOptions.defaultCameraCaptureOptions,
      quality,
    );
    final result = await switching.setEnabled(
      room.localParticipant,
      enabled,
      options: saved == null ? base : base.copyWith(deviceId: saved),
    );
    // Off only mutes, and the next enable reopens the capture front-facing: reset now.
    if (!enabled && result.ok) switching.resetFacing();
    _host.refresh();
    return result;
  }

  /// Opens the camera a join asked for once the call is connected; a leave or
  /// newer join discards its outcome while [current] is false, and a late
  /// open is only turned back off while the room is still [held].
  Future<void> openAfterJoin(
    lk.Room room, {
    required bool Function() current,
    required bool Function() held,
  }) =>
      _join.open(
        enable: () => _setEnabled(room, true),
        current: current,
        noteFailure: _host.noteError,
        abandon: () async {
          if (!held()) return;
          await _setEnabled(room, false);
        },
      );

  /// Drops a join-time open still in flight.
  void cancelJoin() => _join.cancel();

  Widget view(String identity) {
    final room = _host.room();
    if (room == null) return const SizedBox.shrink();
    return CameraView(
      room: room,
      identity: identity,
      facing: switching.facing,
      density: _density,
    );
  }

  Future<void> dispose() async {
    switching.dispose();
    await _join.dispose();
  }
}
