// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fix for the desktop-sheets audit: `whats_new_sheet.dart` used to force a
/// fixed fraction (0.6) of the full window height inside `showAppSheet`'s
/// dialog, leaving most of a desktop dialog empty for genuinely short
/// content. `pinned_messages_sheet` and `threads_sheet` already have their
/// own equivalent coverage (`pinnedMessagesBodyBoxKey`/`threadsBodyBoxKey`);
/// `member_roles_sheet` already had its own last test for the same bug in
/// the sibling sheet this one used to mirror (the role-assign sheet the
/// roles pane's Members tab replaced).
///
/// Each sheet is checked at a compact width (bottom sheet) and a desktop
/// width (dialog): short content must not be forced to the old fixed height
/// at either. The body box itself is measured, not the surrounding `Dialog`
/// - `Dialog`'s own render box fills the available screen space regardless
/// of its content's size, so it cannot tell a short body from a tall one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

const _compactWidth = 500.0;
const _desktopWidth = 1100.0;
const _windowHeight = 900.0;

void main() {
  group("what's new sheet", () {
    const entries = [
      WhatsNewEntry(
        version: '1.0.0',
        headline: 'One small thing',
        points: [WhatsNewPoint('A single short line.')],
      ),
    ];

    for (final width in [_compactWidth, _desktopWidth]) {
      testWidgets('a single short entry at width $width does not force the old '
          '60% of window height', (tester) async {
        tester.view.physicalSize = Size(width, _windowHeight);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showWhatsNewSheet(context, entries),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final height = tester.getSize(find.byKey(whatsNewBodyBoxKey)).height;
        expect(
          height,
          lessThan(_windowHeight * 0.5),
          reason:
              'a single short entry must not be forced to the old fixed '
              '60% of window height',
        );
      });
    }
  });
}
