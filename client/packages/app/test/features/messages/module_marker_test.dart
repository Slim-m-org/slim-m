// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's post carries a host-written marker: "via X" when a person ran
/// the module, "X module" when nobody did, on a grouped continuation too.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart'
    show MessageExtras;
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';

import 'message_row_harness.dart';

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    api.ViaModule? module,
    bool grouped = false,
  }) async {
    await tester.pumpWidget(
      harness(
        MessageRow(
          message: message(authorId: 'u1'),
          grouped: grouped,
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
          extras: MessageExtras(viaModule: module),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a person-run post says via the module', (tester) async {
    await pumpRow(
      tester,
      module: const api.ViaModule(
        id: 'poster',
        name: 'Scorekeeper',
        background: false,
      ),
    );
    expect(find.text('via Scorekeeper'), findsOneWidget);
  });

  testWidgets('a background post names the module as the poster', (
    tester,
  ) async {
    await pumpRow(
      tester,
      module: const api.ViaModule(
        id: 'ticker',
        name: 'Ticker',
        background: true,
      ),
    );
    expect(find.text('Ticker module'), findsOneWidget);
  });

  testWidgets('a grouped continuation keeps the marker', (tester) async {
    await pumpRow(
      tester,
      grouped: true,
      module: const api.ViaModule(
        id: 'poster',
        name: 'Scorekeeper',
        background: false,
      ),
    );
    expect(find.text('via Scorekeeper'), findsOneWidget);
  });

  testWidgets('an ordinary message has no marker', (tester) async {
    await pumpRow(tester);
    expect(find.textContaining('via '), findsNothing);
    expect(find.textContaining(' module'), findsNothing);
  });
}
