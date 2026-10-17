// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message's own actions menu and a report card's moderation action both
/// confirm a delete with `confirmDangerousAction`, and this drives both real
/// call sites - `confirmAndDeleteMessage` (`channel_message_actions.dart`)
/// and `deleteReportedMessage` (`report_card_actions.dart`) - through their
/// actual dialog rather than a hand-typed copy of it, so a future edit that
/// re-diverges the two titles (screen-review overlays.md's low finding)
/// fails here rather than only showing up in a screenshot diff.
///
/// Both calls cancel before reaching a network request, so neither needs the
/// api/store scaffolding the two functions' happy paths do; only the
/// confirmation dialog itself is under test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_card_actions.dart';
import 'package:slimm_app/src/features/channels/screens/channel_message_actions.dart';
import 'package:slimm_app/src/widgets/confirm_dialog.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _message = Message(
  id: 'm1',
  channelId: 'c1',
  seq: 1,
  content: 'hello',
  createdAt: 0,
  pending: false,
  failed: false,
);

Future<void> _pumpButton(
  WidgetTester tester,
  Future<void> Function(BuildContext, WidgetRef) onPressed,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Consumer(
          builder: (context, ref, _) => ElevatedButton(
            onPressed: () => onPressed(context, ref),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("a message's own delete confirmation carries the shared title", (
    tester,
  ) async {
    await _pumpButton(
      tester,
      (context, ref) => confirmAndDeleteMessage(ref, context, _message),
    );

    expect(find.text(deleteMessageConfirmTitle), findsOneWidget);
    expect(find.text(deleteMessageConfirmMessage), findsOneWidget);
  });

  testWidgets(
    "a report card's delete confirmation carries the same shared title",
    (tester) async {
      await _pumpButton(
        tester,
        (context, ref) => deleteReportedMessage(
          context,
          ref,
          ({required whatFailed, required action}) async =>
              fail('the guard must not run before the dialog is confirmed'),
          channelId: 'c1',
          messageId: 'm1',
          reportId: 'r1',
        ),
      );

      expect(find.text(deleteMessageConfirmTitle), findsOneWidget);
      expect(find.text(deleteMessageConfirmMessage), findsOneWidget);
    },
  );
}
