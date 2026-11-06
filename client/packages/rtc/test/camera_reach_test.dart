// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera's ceiling is learned from a short frame and forgotten as soon as
/// another camera, or a taller frame, shows it no longer holds.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('a frame shorter than asked sets the ceiling', () {
    expect(
      nextCameraReach(
        known: null,
        reading: (deviceId: 'cam', asked: 1080, delivered: 720),
      ),
      (deviceId: 'cam', height: 720),
    );
  });

  test('a frame as tall as asked learns nothing new', () {
    expect(
      nextCameraReach(
        known: null,
        reading: (deviceId: 'cam', asked: 720, delivered: 720),
      ),
      isNull,
    );
    expect(
      nextCameraReach(
        known: (deviceId: 'cam', height: 720),
        reading: (deviceId: 'cam', asked: 720, delivered: 720),
      ),
      (deviceId: 'cam', height: 720),
    );
  });

  test('another camera clears a ceiling it never had', () {
    expect(
      nextCameraReach(
        known: (deviceId: 'old', height: 720),
        reading: (deviceId: 'new', asked: 720, delivered: 720),
      ),
      isNull,
    );
  });

  test('a taller frame from the same camera clears its ceiling', () {
    expect(
      nextCameraReach(
        known: (deviceId: 'cam', height: 480),
        reading: (deviceId: 'cam', asked: 720, delivered: 720),
      ),
      isNull,
    );
  });
}
