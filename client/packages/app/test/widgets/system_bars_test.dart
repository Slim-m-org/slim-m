// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Both Android bars stay transparent, so the page shows through them on
/// every OS version, with icons that contrast with it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/system_bars.dart';

void main() {
  test('both bars are transparent in either theme', () {
    for (final theme in Brightness.values) {
      final style = systemBarsFor(theme);
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
    }
  });

  test('icons contrast with the page', () {
    expect(
      systemBarsFor(Brightness.light).statusBarIconBrightness,
      Brightness.dark,
    );
    expect(
      systemBarsFor(Brightness.dark).statusBarIconBrightness,
      Brightness.light,
    );
  });
}
