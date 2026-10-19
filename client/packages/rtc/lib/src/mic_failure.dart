// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why the microphone would not open or went quiet, in the detail the
/// platform lets us tell apart; `camera_failure.dart` is the camera's own.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'os_mic_block.dart';

enum MicFailureReason {
  /// The OS or browser refused this app the microphone.
  permissionDenied,

  /// Another app holds it, or the driver could not open it.
  busy,

  /// No microphone is connected.
  notFound,

  /// It opened but sent nothing through every restart.
  silent,

  unknown,
}

/// Reads the `DOMException` names web fails with, the `NotAllowedError` text
/// Android's permission pre-check uses, and the exception livekit 2.12+ throws
/// on iOS and macOS before the microphone opens.
MicFailureReason classifyMicFailure(Object error) {
  final text = error.toString();
  if (error is lk.TrackCreateException &&
      text.contains('Microphone permission')) {
    return MicFailureReason.permissionDenied;
  }
  if (text.contains('NotAllowedError') || text.contains('PermissionDenied')) {
    return MicFailureReason.permissionDenied;
  }
  if (text.contains('NotReadableError')) return MicFailureReason.busy;
  if (text.contains('NotFoundError') || text.contains('OverconstrainedError')) {
    return MicFailureReason.notFound;
  }
  return MicFailureReason.unknown;
}

/// Whether the OS says this app may not use the microphone, for the desktop
/// platforms whose capture reports a block as silence instead of an error.
typedef OsMicBlockProbe = Future<bool> Function();

/// The platform's own answer, for sessions that are not handed another.
Future<bool> platformMicBlocked() => osBlocksMicrophone();

/// A block is told apart from a dead or busy device only when the OS says so.
Future<MicFailureReason> refineMicFailure(
  MicFailureReason reason,
  OsMicBlockProbe probe,
) async {
  if (reason != MicFailureReason.silent && reason != MicFailureReason.unknown) {
    return reason;
  }
  try {
    return await probe() ? MicFailureReason.permissionDenied : reason;
  } on Object {
    return reason;
  }
}
