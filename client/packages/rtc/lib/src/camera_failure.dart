// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling "no camera exists" apart from "a camera exists but was refused",
/// which the platform gives surprisingly inconsistent evidence for.
///
/// Surveyed the whole stack rather than assumed: on iOS, macOS and web,
/// `getUserMedia` fails with a `DOMException`-shaped name -
/// `NotFoundError`/`OverconstrainedError` for no device, `NotAllowedError` for
/// a denied permission, `NotReadableError` for one already open elsewhere or
/// otherwise unreadable. Android collapses every failure but a pre-flight
/// permission denial into one generic message
/// (`GetUserMediaImpl.getUserMedia`'s own comment: "does not follow the
/// getUserMedia() algorithm... with respect to distinguishing the various
/// causes of failure"). Linux and Windows share flutter_webrtc's `common/cpp`
/// capturer, which never throws for "no camera" at all -
/// `FlutterMediaStream::GetUserVideo` returns silently on zero devices or a
/// capturer that failed to open, and `GetUserMedia` still reports success with
/// an empty video track list. livekit_client's own `LocalTrack.createStream`
/// is what actually notices, throwing [lk.TrackCreateException] whenever a
/// video request comes back with no video track - the one signal every
/// platform funnels through, but on Linux/Windows it cannot tell "no camera"
/// from "a camera that failed to open" apart, since the native layer handed
/// both back as the same empty success.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

/// Why a camera could not be turned on, in the detail the platform actually
/// supports telling apart.
enum CameraFailureReason {
  /// No camera device exists for this platform to open.
  noCameraDetected,

  /// A camera exists, but the app was not allowed to use it.
  permissionDenied,

  /// A camera exists, but the platform could not open it right now: already
  /// in use elsewhere, or a driver failure indistinguishable from that.
  cameraUnavailable,

  /// A camera exists (or that could not be checked), and the platform gave
  /// no reason for the refusal beyond the raw failure itself.
  unknown,

  /// The camera picked earlier is gone from the device list while others remain.
  chosenCameraUnavailable,
}

/// The cause of [CameraFailureReason.chosenCameraUnavailable].
class ChosenCameraUnavailable implements Exception {
  const ChosenCameraUnavailable();

  @override
  String toString() => 'The camera you chose is not available.';
}

/// Classifies why enabling the camera failed.
///
/// [hasDevice] is an independent enumeration answer (`Hardware.videoInputs`),
/// `null` when that could not be asked either. It takes priority over
/// anything read out of [error]'s own text: enumeration is a direct question
/// answered by the platform's device list, where the error text is, on most
/// platforms, not actually distinguishing (see the library doc). Only when
/// [hasDevice] is `true` or unknown does the error's own shape get a say, and
/// even then only for the handful of tokens platforms actually agree on.
CameraFailureReason classifyCameraFailure(Object error, {bool? hasDevice}) {
  if (hasDevice == false) return CameraFailureReason.noCameraDetected;
  final text = error.toString();
  if (text.contains('NotAllowedError')) {
    return CameraFailureReason.permissionDenied;
  }
  if (text.contains('NotReadableError')) {
    return CameraFailureReason.cameraUnavailable;
  }
  if (text.contains('NotFoundError') || text.contains('OverconstrainedError')) {
    return CameraFailureReason.noCameraDetected;
  }
  if (error is lk.TrackCreateException) {
    return hasDevice == true
        ? CameraFailureReason.cameraUnavailable
        : CameraFailureReason.unknown;
  }
  return CameraFailureReason.unknown;
}

/// A camera-enable failure carrying both [reason] and the raw platform
/// [cause], so [VoiceSession.lastError] can keep handing back one `Object?`
/// - every existing caller that only reads it as a string via [toString]
/// keeps working unchanged, while [reason] is there for a caller that wants
/// to choose specific copy.
class CameraFailure {
  const CameraFailure(this.cause, this.reason);

  final Object cause;
  final CameraFailureReason reason;

  @override
  String toString() => cause.toString();
}
