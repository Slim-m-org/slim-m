// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picker filters keep camera-style upper-case names selectable on Linux.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/picker_extensions.dart';

void main() {
  test('Linux gets an upper-case twin for each extension', () {
    expect(pickerExtensions(['png', 'jpg'], platform: TargetPlatform.linux), [
      'png',
      'PNG',
      'jpg',
      'JPG',
    ]);
  });

  test('other platforms pass the list through', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      expect(pickerExtensions(['png'], platform: platform), ['png']);
    }
  });
}
