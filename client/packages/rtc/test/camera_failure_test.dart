// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for telling why a camera enable failed, per the survey in
/// `camera_failure.dart`'s own library doc: enumeration is the reliable
/// signal, and the error text only gets a say where a platform actually
/// agrees on one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  group('classifyCameraFailure', () {
    test('no enumerated device wins over an unrecognised error', () {
      expect(
        classifyCameraFailure('Unable to getUserMedia: nope', hasDevice: false),
        CameraFailureReason.noCameraDetected,
      );
    });

    test('a NotAllowedError is a permission denial', () {
      expect(
        classifyCameraFailure(
          'Unable to getUserMedia: NotAllowedError',
          hasDevice: true,
        ),
        CameraFailureReason.permissionDenied,
      );
    });

    test('a NotReadableError means the device could not be opened', () {
      expect(
        classifyCameraFailure(
          'Unable to getUserMedia: NotReadableError',
          hasDevice: true,
        ),
        CameraFailureReason.cameraUnavailable,
      );
    });

    test('a NotFoundError is no camera even with hasDevice unknown', () {
      expect(
        classifyCameraFailure('Unable to getUserMedia: NotFoundError'),
        CameraFailureReason.noCameraDetected,
      );
    });

    test('an OverconstrainedError is no camera', () {
      expect(
        classifyCameraFailure(
          'Unable to getUserMedia: OverconstrainedError',
          hasDevice: true,
        ),
        CameraFailureReason.noCameraDetected,
      );
    });

    test(
      'a TrackCreateException with a confirmed device is unavailable, not absent',
      () {
        expect(
          classifyCameraFailure(lk.TrackCreateException(), hasDevice: true),
          CameraFailureReason.cameraUnavailable,
        );
      },
    );

    test(
      'a TrackCreateException with no device confirmation is unknown, not guessed at',
      () {
        expect(
          classifyCameraFailure(lk.TrackCreateException()),
          CameraFailureReason.unknown,
        );
      },
    );

    test('a generic error with no enumeration answer is unknown', () {
      expect(
        classifyCameraFailure(
            'Unable to getUserMedia: Failed to create new track.'),
        CameraFailureReason.unknown,
      );
    });
  });

  group('CameraFailure', () {
    test('toString reads as the raw cause, not the reason', () {
      final failure = const CameraFailure(
        'Unable to getUserMedia: NotFoundError',
        CameraFailureReason.noCameraDetected,
      );
      expect(failure.toString(), 'Unable to getUserMedia: NotFoundError');
    });
  });
}
