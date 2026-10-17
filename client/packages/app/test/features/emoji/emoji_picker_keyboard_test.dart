// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keyboard navigation of the desktop emoji panel, split from
/// `emoji_picker_test.dart` when that file crossed the size ceiling.
///
/// The panel opens with no cell highlighted: index 0 used to be the default,
/// which painted an accent border on the first tile the instant the panel
/// appeared (owner-reported 2026-09-03). A search highlights its first
/// result so Enter picks it; arrow keys move into the grid from the
/// no-highlight state, down at the first cell and up at the last.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';

const _grinningFace = '\u{1F600}'; // First catalog entry (smileys, default).

Widget _harness(Widget child) => ProviderScope(
  overrides: [customEmojiProvider.overrideWith((ref) => const <CustomEmoji>[])],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  testWidgets('the panel opens with no cell highlighted', (tester) async {
    await tester.pumpWidget(
      _harness(EmojiPickerPanel(onSelect: (_) {}, onClose: () {})),
    );
    await tester.pump();

    // No highlighted cell on open (the stray first-tile border, owner-reported 2026-09-03); read the cell's own flag, so the active-category chip is not mistaken for it.
    final cells = tester.widgetList<EmojiCell>(find.byType(EmojiCell));
    expect(cells, isNotEmpty, reason: 'the grid rendered');
    expect(cells.where((c) => c.highlighted), isEmpty);
  });

  testWidgets('arrow-down enters the grid at the first cell and Enter picks it', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _harness(
        EmojiPickerPanel(onSelect: (emoji) => picked = emoji, onClose: () {}),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Per flutter_test docs a raw Enter never reaches onSubmitted; the engine turns it into one on a real device.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // First entry, not second: one press down from no-highlight lands on the first cell rather than skipping it.
    expect(picked, _grinningFace);
  });

  testWidgets('arrow-up from the open state enters at the last cell', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _harness(
        EmojiPickerPanel(onSelect: (emoji) => picked = emoji, onClose: () {}),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Something was picked, and it was not the first cell: up wrapped to the end.
    expect(picked, isNotNull);
    expect(picked, isNot(_grinningFace));
  });
}
