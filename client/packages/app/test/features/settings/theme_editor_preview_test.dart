// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's pinned preview: what repaints while a colour changes, and how
/// it folds to a short strip as the column scrolls under it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';
import 'theme_gallery_rig.dart' show stored;

Color? _linkColour(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: byKey('theme-editor-preview'),
        matching: find.text('Link to the build'),
      ),
    )
    .style!
    .color;

void main() {
  testWidgets('a colour change repaints the preview, not the header or '
      'Details', (tester) async {
    final rig = EditorRig(storeThemes: [stored('t1', 'Pine', author: 'ren')]);
    await rig.open(tester);
    await tapIn(tester, byKey('theme-main-accent'));
    final hex = find.byKey(AppColourPicker.hexFieldKey);
    await tester.enterText(hex, '40A0D0');
    await settle(tester);
    final menu = tester.widget(byKey('theme-editor-menu'));
    final startFrom = tester.widget(byKey('theme-editor-start-from'));
    final before = _linkColour(tester);

    await tester.enterText(hex, 'D04040');
    await tester.pump();

    expect(_linkColour(tester), isNot(before));
    expect(identical(tester.widget(byKey('theme-editor-menu')), menu), isTrue);
    expect(
      identical(tester.widget(byKey('theme-editor-start-from')), startFrom),
      isTrue,
    );
  });
}
