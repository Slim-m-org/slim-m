// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every theme's mention highlight clears one visibility floor, so no theme
/// (forest was the report) reads weaker than the default.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  final themes = {
    'light': AppTokens.light,
    'dark': AppTokens.dark,
    'trueBlack': AppTokens.trueBlack,
    'mocha': AppTokens.mocha,
    'soft': AppTokens.soft,
    'forest': AppTokens.forest,
    'halloween': AppTokens.halloween,
  };

  themes.forEach((name, t) {
    test('$name mention row is visible', () {
      final bar = contrastRatio(t.mentionRowBar, t.surfaceBase);
      final barOnFill = contrastRatio(t.mentionRowBar, t.mentionRowFill);
      final fill = contrastRatio(t.mentionRowFill, t.surfaceBase);
      final outline = contrastRatio(t.mentionPillOutline, t.mentionRowFill);
      expect(bar, greaterThanOrEqualTo(3), reason: '$name bar on page');
      expect(barOnFill, greaterThanOrEqualTo(3), reason: '$name bar on fill');
      expect(fill, greaterThanOrEqualTo(1.15), reason: '$name fill on page');
      expect(outline, greaterThanOrEqualTo(1.4), reason: '$name pill outline');
    });
  });
}
