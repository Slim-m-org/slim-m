// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `cameraFailureMessage` turns a camera toggle failure into what the user
/// reads. Two rules were untested: a reason-specific message is shown only when
/// turning the camera *on* (a failure to turn it off is never "permission
/// denied", which is about access, not release), and the fallback names the
/// direction that failed and trims a missing cause rather than leaving a
/// dangling space.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_camera_failure.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('turning on surfaces the specific reason', () {
    expect(
      cameraFailureMessage(
        true,
        const CameraFailure('boom', CameraFailureReason.permissionDenied),
      ),
      contains('denied'),
    );
    expect(
      cameraFailureMessage(
        true,
        const CameraFailure('boom', CameraFailureReason.noCameraDetected),
      ),
      contains('No camera detected'),
    );
  });

  test('turning off never shows a reason, only the generic off message', () {
    final message = cameraFailureMessage(
      false,
      const CameraFailure('boom', CameraFailureReason.permissionDenied),
    );
    expect(message, contains('off'));
    expect(message, isNot(contains('denied')));
  });

  test(
    'a non-CameraFailure cause falls back to the direction and the cause',
    () {
      final message = cameraFailureMessage(true, 'raw error');
      expect(message, contains('on'));
      expect(message, contains('raw error'));
    },
  );

  test('a null cause is trimmed, leaving no dangling space', () {
    expect(cameraFailureMessage(true, null), 'Could not turn the camera on.');
  });
}
