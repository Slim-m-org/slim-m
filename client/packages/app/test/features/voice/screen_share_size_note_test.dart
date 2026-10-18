// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A resolution bigger than the screen says it will be shared at screen size.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/video_quality_labels.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('says nothing for a tier the screen can show', () {
    expect(screenShareSizeNote(ScreenShareResolution.p1080, 1080), isNull);
  });

  test('explains a tier above the screen', () {
    expect(
      screenShareSizeNote(ScreenShareResolution.p2160, 1080),
      contains('shared at your screen size'),
    );
  });

  test('says nothing when the display is unknown', () {
    expect(screenShareSizeNote(ScreenShareResolution.p2160, null), isNull);
  });
}
