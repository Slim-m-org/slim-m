// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transcript's hand-on moments travel instead of hard-cutting: a send
/// confirming cross-fades its time mark and lerps its body ink, and a
/// removed reaction chip pops out where it stood rather than vanishing.
/// Each test reads the mid-flight state - both marks mounted, an ink colour
/// strictly between the two ends, the fading remains still on screen - so
/// reverting any one animation to the old snap fails exactly its own test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/reactions_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

void main() {
  testWidgets('a send confirming cross-fades the time mark', (tester) async {
    var msg = message(pending: true);
    late StateSetter setMessage;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            setMessage = setState;
            return MessageTimeMark(message: msg);
          },
        ),
        overrides: [
          timeFormatControllerProvider.overrideWith(
            (ref) =>
                TimeFormatController(ref)..state = TimeFormatPreference.h24,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sending'), findsOneWidget);

    setMessage(() => msg = message(pending: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(
      find.text('sending'),
      findsOneWidget,
      reason: 'mid-swap the pending mark is still fading out',
    );
    expect(
      find.text(formatMessageTime(1700000000000, use24Hour: true)),
      findsOneWidget,
      reason: 'while the delivered time fades in beside it',
    );
    await tester.pumpAndSettle();
    expect(find.text('sending'), findsNothing);
  });

  testWidgets('a send confirming lerps the body ink rather than snapping', (
    tester,
  ) async {
    var dim = true;
    late StateSetter setDim;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            setDim = setState;
            return MessageBody(
              content: 'hello there',
              knownUsernames: const {},
              dim: dim,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color inkNow() {
      final rich = tester.widget<Text>(find.byType(Text).first);
      return (rich.textSpan! as TextSpan).style!.color!;
    }

    final tokens = AppTokens.light;
    expect(inkNow(), tokens.textSecondary);

    setDim(() => dim = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final mid = inkNow();
    expect(mid, isNot(tokens.textSecondary), reason: 'the ink has set off');
    expect(mid, isNot(tokens.textPrimary), reason: 'and has not arrived yet');
    await tester.pumpAndSettle();
    expect(inkNow(), tokens.textPrimary);
  });

  testWidgets('a removed reaction chip pops out where it stood', (
    tester,
  ) async {
    const a = api.ReactionSummary(emoji: 'A', count: 1, reacted: false);
    const b = api.ReactionSummary(emoji: 'B', count: 2, reacted: true);
    const c = api.ReactionSummary(emoji: 'C', count: 3, reacted: false);
    var reactions = const [a, b, c];
    late StateSetter setReactions;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            setReactions = setState;
            return ReactionsRow(reactions: reactions, onReactionTap: (_) {});
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    setReactions(() => reactions = const [a, c]);
    await tester.pump();
    expect(
      find.text('B'),
      findsOneWidget,
      reason: 'the removed chip stays mounted while its exit plays',
    );
    final exiting = tester.getCenter(find.text('B'));
    final after = tester.getCenter(find.text('C'));
    expect(
      exiting.dx,
      lessThan(after.dx),
      reason: 'and it fades where it stood, never teleporting to the end',
    );
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
  });
}
