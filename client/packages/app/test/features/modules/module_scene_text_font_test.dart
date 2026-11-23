// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scene text is drawn by a bare `TextPainter`, which inherits no theme, so the
/// app face has to be named on its style or it falls back to the engine default.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('scene text names the app sans family and the emoji fallback', () {
    final style = moduleSceneTextStyle(color: Colors.black, fontSize: 12);

    expect(style.fontFamily, AppFonts.sans);
    expect(style.fontFamilyFallback, AppFonts.emoji);
    expect(style.fontSize, 12);
    expect(style.color, Colors.black);
  });
}
