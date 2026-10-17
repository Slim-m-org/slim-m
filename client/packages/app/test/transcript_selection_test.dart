// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one property this wrapper exists for: it must not claim the press
/// gesture on a phone, where that gesture already raises the message sheet.
///
/// The right-click suite guards a second property found the same way: on
/// desktop, `SelectionArea`'s own toolbar must never raise beside the
/// message context menu.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/transcript_selection.dart';

Widget _app(TargetPlatform platform) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: const Scaffold(
    body: TranscriptSelection(child: Text('a message body')),
  ),
);

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform leaves the press gesture to the action sheet', (
      tester,
    ) async {
      await tester.pumpWidget(_app(platform));
      expect(
        find.byType(SelectionArea),
        findsNothing,
        reason: 'a long press on touch must open the sheet, not select text',
      );
      expect(find.text('a message body'), findsOneWidget);
    });
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('$platform can select message text', (tester) async {
      await tester.pumpWidget(_app(platform));
      expect(find.byType(SelectionArea), findsOneWidget);
    });
  }

  test('the predicate names touch platforms, not a window size', () {
    expect(supportsTextSelection(TargetPlatform.iOS), isFalse);
    expect(supportsTextSelection(TargetPlatform.android), isFalse);
    expect(supportsTextSelection(TargetPlatform.linux), isTrue);
    expect(supportsTextSelection(TargetPlatform.fuchsia), isTrue);
  });

  // Backlog item 57: a right-click also raised SelectionArea's own popup.
  testWidgets(
    'a right-click on desktop does not also raise the platform selection '
    'menu',
    (tester) async {
      await tester.pumpWidget(_app(TargetPlatform.linux));

      await tester.tapAt(
        tester.getCenter(find.text('a message body')),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsNothing,
        reason:
            'the message context menu is the one right-click menu; the '
            'platform "Select all" popup must not also open',
      );
    },
  );
}
