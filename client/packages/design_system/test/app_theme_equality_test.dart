// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// MaterialApp's AnimatedTheme cross-fades whenever the theme it is handed
/// differs from the last one, so a theme built from closures (which never
/// compare equal) restarts that animation on every rebuild of the app root.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  for (final (brightness, tokens) in [
    (Brightness.dark, AppTokens.dark),
    (Brightness.light, AppTokens.light),
  ]) {
    test('two builds of the $brightness theme compare equal', () {
      expect(buildTheme(brightness, tokens), buildTheme(brightness, tokens));
    });
  }
}
