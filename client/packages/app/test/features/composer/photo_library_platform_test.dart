// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Only iOS has the in-composer photo strip; Android uses the system picker.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library_native.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS gets a photo library for the strip', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(createPhotoLibrary(), isNotNull);
  });

  test(
    'Android, sideloaded or Play, gets none, so both entries open one picker',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(createPhotoLibrary(), isNull);
    },
  );

  test('desktop gets none', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(createPhotoLibrary(), isNull);
  });
}
