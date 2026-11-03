// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A continuation's body keeps the width a headed row's body has, even in a
/// narrow docked pane: the hover toolbar's right reserve must not squeeze it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart'
    show MessageExtras;
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';

import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'message_row_harness.dart';

const _text =
    'Here is your picture [source](https://example.com/photo/barack) '
    'Photo credit: Official White House Photo by Someone Else, shown here '
    'with enough words that it has to wrap in any pane narrower than a page';

MessageRow _row(String id, bool grouped) => MessageRow(
  key: ValueKey(id),
  message: message(id: id, content: _text),
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
  extras: const MessageExtras(),
);

double _bodyWidth(WidgetTester tester, String id) => tester
    .getSize(
      find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.textContaining('Here is your', findRichText: true),
      ),
    )
    .width;

void main() {
  setUpAll(loadRealFonts);

  for (final pane in [340.0, 420.0, 480.0]) {
    testWidgets(
      'a grouped body is as wide as a headed one in a ${pane}px pane',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          harness(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: pane,
                child: ListView(
                  children: [_row('headed', false), _row('grouped', true)],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final headed = _bodyWidth(tester, 'headed');
        expect(headed, greaterThan(pane * 0.6));
        expect(_bodyWidth(tester, 'grouped'), closeTo(headed, 1));
      },
    );
  }
}
