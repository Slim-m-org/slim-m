// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message whose text a moderator rewrote says so where "edited" sits.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

Future<void> _pumpRow(WidgetTester tester, Message shown) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: MessageRow(
          message: shown,
          grouped: false,
          showNewDivider: false,
          knownUsernames: const {},
          actions: noActions,
          editing: false,
          callbacks: MessageRowCallbacks(
            onRetry: () {},
            onDiscard: () {},
            onPickReaction: (_) {},
            onReactionTap: (_) {},
            onVote: (_) {},
            onSubmitEdit: (_) {},
            onCancelEdit: () {},
          ),
        ),
      ),
    ),
  ),
);

Message _edited({required bool byModerator}) => Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'author-1',
  authorDisplayName: 'Priya',
  seq: 5,
  content: 'kind words',
  createdAt: 1700000000000,
  editedAt: 1700000060000,
  editedByModerator: byModerator,
  pending: false,
  failed: false,
);

void main() {
  testWidgets('a moderator edit reads "edited by a moderator"', (tester) async {
    await _pumpRow(tester, _edited(byModerator: true));
    await tester.pump();

    expect(find.text('edited by a moderator'), findsOneWidget);
    expect(find.text('edited'), findsNothing);
  });

  testWidgets('the author\'s own edit still reads "edited"', (tester) async {
    await _pumpRow(tester, _edited(byModerator: false));
    await tester.pump();

    expect(find.text('edited'), findsOneWidget);
    expect(find.text('edited by a moderator'), findsNothing);
  });
}
