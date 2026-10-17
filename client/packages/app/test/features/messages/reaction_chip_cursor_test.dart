// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reaction chip is a button, but it rendered inside the transcript's
/// `SelectionArea`, so its emoji and count were selectable text: hovering
/// showed the I-beam instead of the click cursor, and a drag selected the
/// emoji as text. The row now opts out of selection, as the spoiler does.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _inSelectionArea() => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('some selectable message text'),
          ReactionsRow(
            reactions: const [
              api.ReactionSummary(emoji: '\u{1F44D}', count: 1, reacted: false),
            ],
            onReactionTap: (_) {},
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'hovering a reaction chip inside a SelectionArea shows the click cursor, '
    'not the text I-beam',
    (tester) async {
      await tester.pumpWidget(_inSelectionArea());
      await tester.pumpAndSettle();
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(AppChip).first));
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
    },
  );

  testWidgets('the chips sit outside the selection region', (tester) async {
    await tester.pumpWidget(_inSelectionArea());
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byType(AppChip).first,
        matching: find.byWidgetPredicate(
          (w) => w is SelectionContainer && w.delegate == null,
        ),
      ),
      findsOneWidget,
      reason: 'SelectionContainer.disabled is the opt-out the spoiler uses',
    );
  });
}
