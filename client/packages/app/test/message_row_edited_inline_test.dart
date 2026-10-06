// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edited marker reads as a word at the end of the message, not as a link
/// on a line of its own: "edited" with no parentheses, trailing the last word
/// of the body, underlined only when the history behind it can be opened.
///
/// Geometry throughout. A marker that exists but sits under the body, or one
/// that is underlined when it does nothing, is the bug.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _longBody =
    'the resync path replays every op after the last seen seq, so a client '
    'that was offline for an hour sends one request and applies the tail '
    'strictly in order';

Widget _row(
  String content, {
  VoidCallback? onHistory,
  double width = 600,
  int? editedAt = 1700000900000,
}) => harness(
  Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      child: MessageRow(
        message: message(content: content, editedAt: editedAt),
        grouped: false,
        showNewDivider: false,
        knownUsernames: const {},
        actions: noActions,
        editing: false,
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: (_) {},
          onCancelEdit: noop,
          onViewEditHistory: onHistory,
        ),
      ),
    ),
  ),
);

Finder get _marker => find.text('edited');

TextStyle _markerStyle(WidgetTester tester) =>
    tester.widget<Text>(_marker).style!;

void main() {
  testWidgets('it says edited, with no parentheses', (tester) async {
    await tester.pumpWidget(_row('short one'));
    expect(_marker, findsOneWidget);
    expect(find.text('(edited)'), findsNothing);
  });

  testWidgets('it trails the last word on the same line for a short body', (
    tester,
  ) async {
    await tester.pumpWidget(_row('short one'));

    final marker = tester.getRect(_marker);
    final body = tester.getRect(find.byType(MessageBody));
    expect(marker.top, greaterThanOrEqualTo(body.top));
    expect(
      marker.bottom,
      lessThanOrEqualTo(body.bottom + 1),
      reason: 'inside the body box, not on a line below it',
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.textContaining('short one'),
    );
    final word = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 9),
        )
        .last
        .toRect()
        .shift(paragraph.localToGlobal(Offset.zero));
    expect(marker.left, greaterThan(word.right - 1));
    expect(
      marker.center.dy,
      closeTo(word.center.dy, 4),
      reason: 'one line with the last word',
    );
  });

  testWidgets('it trails the last wrapped line of a long body', (tester) async {
    await tester.pumpWidget(_row(_longBody, width: 420));

    final marker = tester.getRect(_marker);
    final body = tester.getRect(find.byType(MessageBody));
    expect(
      body.height,
      greaterThan(AppText.body.fontSize! * 2.5),
      reason: 'the fixture really wraps',
    );
    expect(marker.bottom, lessThanOrEqualTo(body.bottom + 1));
    expect(
      marker.top,
      greaterThan(body.bottom - AppText.body.fontSize! * 2),
      reason: 'on the last line, not the first',
    );
  });

  testWidgets('it is underlined only when history can be opened', (
    tester,
  ) async {
    await tester.pumpWidget(_row('short one', onHistory: noop));
    expect(_markerStyle(tester).decoration, TextDecoration.underline);

    await tester.pumpWidget(_row('short one'));
    expect(
      _markerStyle(tester).decoration ?? TextDecoration.none,
      TextDecoration.none,
    );
  });

  testWidgets('tapping it opens the history', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_row('short one', onHistory: () => opened++));

    await tester.tap(_marker);
    expect(opened, 1);
  });

  testWidgets('a body that ends in code leaves it on its own line below', (
    tester,
  ) async {
    await tester.pumpWidget(_row('look\n```\nlet x = 1;\n```'));
    await tester.pump();

    final marker = tester.getRect(_marker);
    final code = tester.getRect(find.textContaining('let x'));
    expect(marker.top, greaterThanOrEqualTo(code.bottom));
    expect(marker.left, lessThan(code.left + 40));
  });

  testWidgets('a message with no body keeps the marker on a line of its own', (
    tester,
  ) async {
    await tester.pumpWidget(_row(''));

    expect(_marker, findsOneWidget);
    expect(find.byType(MessageBody), findsNothing);
  });

  testWidgets('an unedited message shows none', (tester) async {
    await tester.pumpWidget(_row('short one', editedAt: null));
    expect(_marker, findsNothing);
  });
}
