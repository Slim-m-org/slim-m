// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Flipping or picking a camera, split out of `voice_session.dart` to make
/// room there under this repo's file budget.
///
/// Mirrors `screen_share_control.dart`'s own shape: the room is handed in per
/// call rather than held here, so this stays a plain, test-friendly class
/// with no LiveKit connection of its own to fake.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'camera_devices.dart';
import 'camera_failure.dart';
import 'voice_models.dart';

/// Which physical camera a mobile flip landed on. Desktop's device picker
/// has no such concept - a webcam is not "front" or "back" - so this is
/// only ever moved by [CameraSwitching.flip], and defaults to [front] to
/// match `CameraCaptureOptions`' own default for a fresh camera publish.
enum CameraFacing { front, back }

/// Whether [CameraView] should mirror a camera preview, the same rule an
/// actual mirror follows: only ever the face looking into it. A local front
/// camera mirrors; a local back one does not, since a rear camera already
/// shows the world the way everyone else sees it; and a remote
/// participant's camera is never mirrored regardless of [facing], because
/// that value only ever describes this device's own camera.
lk.VideoViewMirrorMode mirrorModeFor({
  required bool isLocal,
  required CameraFacing facing,
}) {
  if (!isLocal) return lk.VideoViewMirrorMode.off;
  return facing == CameraFacing.front
      ? lk.VideoViewMirrorMode.mirror
      : lk.VideoViewMirrorMode.off;
}

/// The facing a completed [CameraSwitching.flip] landed on, from native
/// `Helper.switchCamera`'s own answer. That bool is `isFrontCamera` *after*
/// the swap, true only when the swap landed on the front camera - never a
/// success flag, since a flip onto the back camera answers `false` on total
/// success. Pulled out on its own because [CameraSwitching.flip] itself
/// needs a real `lk.LocalParticipant` (privately constructed by
/// livekit_client, unfakeable from here) to reach this line at all, so this
/// mapping is the one piece of that method a test can actually drive.
CameraFacing facingAfterSwitch(bool isFrontCamera) =>
    isFrontCamera ? CameraFacing.front : CameraFacing.back;

/// What came of a camera enable/disable attempt. [reason] is only ever set
/// alongside a failed *enable* (see [CameraSwitching.setEnabled]), since
/// "no camera detected" has no sensible reading for a camera that was
/// already on and failed to turn off.
class CameraToggleResult {
  const CameraToggleResult.ok()
      : cause = null,
        reason = null;

  const CameraToggleResult.failed(this.cause, this.reason);

  bool get ok => cause == null;

  final Object? cause;
  final CameraFailureReason? reason;

  /// What [VoiceSession] should store as `lastError`: [cause] wrapped in a
  /// [CameraFailure] when [reason] is known, so that one getter keeps
  /// answering every failure while still letting a caller ask this apart.
  Object? get error =>
      reason == null || cause == null ? cause : CameraFailure(cause!, reason!);
}

class CameraSwitching {
  CameraSwitching(this._devices);

  final CameraDevices _devices;

  final ValueNotifier<CameraFacing> _facing = ValueNotifier(
    CameraFacing.front,
  );

  /// The facing this session's camera is assumed to show right now, moved
  /// only by [flip] and reset by [resetFacing]. [CameraView] listens to
  /// this directly rather than to any LiveKit room event, because [flip]'s
  /// native call bypasses the room entirely and fires none.
  ValueListenable<CameraFacing> get facing => _facing;

  /// Resets the tracked facing to the platform default (front): a fresh
  /// camera publish always requests the front camera (`CameraCaptureOptions`'
  /// own default), so nothing here should keep remembering a flip from a
  /// camera that has since gone away.
  void resetFacing() => _facing.value = CameraFacing.front;

  /// Releases [facing]'s listeners. Session-scoped, not a widget's, so
  /// nothing but [VoiceSession.dispose] calls this.
  void dispose() => _facing.dispose();

  /// Whether flipping between a front and back camera needs no chosen
  /// device: mobile only, where the OS - not a list - decides which camera
  /// answers "front" or "back". See [needsSelection] for the opposite case.
  bool get canFlip => lk.lkPlatformIsMobile();

  /// Whether picking a camera needs one named first, the same reason
  /// `screenShareNeedsSource` exists: several desktop webcams are otherwise
  /// indistinguishable to whatever camera the OS opens by default.
  bool get needsSelection => !lk.lkPlatformIsMobile();

  /// The cameras this platform offers, collapsed to one entry per physical
  /// device; see [dedupeCameraDevices] for why the raw enumeration cannot be
  /// trusted as-is.
  Future<List<CameraDevice>> devices() async =>
      dedupeCameraDevices(await _devices.list());

  /// Enables or disables [local]'s camera, classifying the failure when
  /// enabling does not work.
  ///
  /// A disable failure is reported with no [CameraFailureReason.noCameraDetected]
  /// framing: the camera was already on, so a device plainly exists, and the
  /// caller (`VoiceSession._trySetCamera`) does not ask for one in that case.
  /// [_devices] is only consulted here, on failure, rather than on every
  /// attempt: it is an extra round trip that only the error message needs.
  Future<CameraToggleResult> setEnabled(
    lk.LocalParticipant? local,
    bool enabled, {
    lk.CameraCaptureOptions? options,
  }) async {
    if (local == null) return const CameraToggleResult.ok();
    try {
      await local.setCameraEnabled(enabled, cameraCaptureOptions: options);
      return const CameraToggleResult.ok();
    } catch (e) {
      if (!enabled) return CameraToggleResult.failed(e, null);
      bool? hasDevice;
      try {
        hasDevice = (await _devices.list()).isNotEmpty;
      } catch (_) {
        hasDevice = null;
      }
      return CameraToggleResult.failed(
        e,
        classifyCameraFailure(e, hasDevice: hasDevice),
      );
    }
  }

  /// Flips [local]'s published camera between front and back. Native
  /// `Helper.switchCamera` with no device id is the platform's own flip: it
  /// asks the OS which camera answers next rather than naming one.
  ///
  /// Success here is "the native call completed", never its own returned
  /// bool: that value is `isFrontCamera` *after* the swap, true only when
  /// the swap landed on the front camera - so a flip onto the back camera
  /// reports `false` on total success. Reading that as a failure is exactly
  /// the false "could not switch" error a real flip used to surface; the
  /// bool is [facing] material now, never a success flag.
  Future<bool> flip(lk.LocalParticipant? local) async {
    if (local == null) return false;
    for (final pub in local.videoTrackPublications) {
      if (pub.source != lk.TrackSource.camera) continue;
      final track = pub.track;
      if (track == null) continue;
      final isFront = await webrtc.Helper.switchCamera(track.mediaStreamTrack);
      _facing.value = facingAfterSwitch(isFront);
      return true;
    }
    return false;
  }

  /// Switches [room]'s published camera to [device], desktop's answer to
  /// [flip] where more than one webcam can exist. Also updates the room's
  /// default capture device, so a camera enabled again later opens the one
  /// just chosen rather than reverting to the platform default.
  Future<void> select(lk.Room room, CameraDevice device) =>
      room.setVideoInputDevice(
          lk.MediaDevice(device.id, device.label, 'videoinput', null));
}
