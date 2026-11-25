// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Play bundle drops the photo permissions, so it has no photo strip.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/photo_library_native.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a phone gets a photo library outside the Play build', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(createPhotoLibrary(isPlayBuild: false), isNotNull);
  });

  test('the Play build gets none, so the system picker opens', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(createPhotoLibrary(isPlayBuild: true), isNull);
  });
}
