// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Camera qualities the last camera could not deliver are shown but greyed,
/// struck through, with the reason, and the pick shows what it really gets.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/camera_reach.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  const reach = (deviceId: 'cam', height: 720);

  test('qualities above the camera are out of reach, with why', () {
    expect(
      cameraQualityOutOfReach(CameraQuality.high, reach),
      contains('720p'),
    );
    expect(cameraQualityOutOfReach(CameraQuality.balanced, reach), isNull);
    expect(cameraQualityOutOfReach(CameraQuality.high, null), isNull);
  });

  test('the lowest quality is always offered', () {
    expect(
      cameraQualityOutOfReach(CameraQuality.dataSaver, (
        deviceId: 'cam',
        height: 240,
      )),
      isNull,
    );
  });

  test('a pick beyond the camera shows the tallest it reaches', () {
    expect(
      effectiveCameraQuality(CameraQuality.high, reach),
      CameraQuality.balanced,
    );
    expect(
      effectiveCameraQuality(CameraQuality.high, null),
      CameraQuality.high,
    );
  });

  test('the note names the ceiling only when something is out of reach', () {
    expect(cameraReachNote(reach), 'Your camera tops out at 720p.');
    expect(cameraReachNote(null), isNull);
    expect(cameraReachNote((deviceId: 'cam', height: 1080)), isNull);
  });
}
