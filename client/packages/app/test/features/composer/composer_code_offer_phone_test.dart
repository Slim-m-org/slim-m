// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone the paste-as-code offer names the language in full instead of
/// cutting it to "That looks like Pyth...".
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui_snapshot_fonts.dart';
import 'composer_harness.dart';

void main() {
  setUpAll(loadRealFonts);
  testWidgets('the offer text is not truncated at 390', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.iOS,
        brightness: Brightness.dark,
      ),
    );
    const pasted = 'def add(a, b):\n    return a + b\n\nprint(add(1, 2))';
    controller.value = const TextEditingValue(
      text: pasted,
      selection: TextSelection.collapsed(offset: pasted.length),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final text = tester.renderObject<RenderParagraph>(
      find.textContaining('That looks like'),
    );
    expect(text.didExceedMaxLines, isFalse);
  });
}
