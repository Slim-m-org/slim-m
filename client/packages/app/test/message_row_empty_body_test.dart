// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the row shape an attachment-only message takes.
///
/// The defect: the row built [MessageBody] unconditionally, so a message
/// carrying nothing but a photo drew a blank text line between the author
/// header and the image. It was unreachable until the composer learned to
/// send with no caption, and arrived with it.
///
/// It is measured rather than eyeballed: an empty body renders no glyphs, so
/// nothing about the tree says it is there. Only the gap does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_extras.dart' show MessageExtras;
import 'package:slimm_app/src/widgets/attachment_view.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

/// A text file, not an image: it renders its own chip from data already in
/// hand, so no byte fetch has to resolve before the row can be measured.
const _attachment = api.Attachment(
  id: 'a1',
  filename: 'notes.txt',
  contentType: 'text/plain',
  size: 2048,
);

Widget _row(String content) => harness(
  MessageRow(
    message: message(content: content),
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
    extras: MessageExtras(attachments: const [_attachment]),
  ),
);

/// The vertical distance from the bottom of the author name to the top of the
/// attachment: the header's own bottom padding, the body if there is one, and
/// the attachment's top padding.
double _gapBelowHeader(WidgetTester tester) =>
    tester.getTopLeft(find.byType(AttachmentView)).dy -
    tester.getBottomLeft(find.text('Priya')).dy;

void main() {
  testWidgets('an attachment with no caption draws no body line at all', (
    tester,
  ) async {
    await tester.pumpWidget(_row(''));
    await tester.pump();

    // The measurement comes first deliberately: the widget being absent is
    // the mechanism, and the gap is the defect a reader would actually see.
    expect(
      _gapBelowHeader(tester),
      AppSpacing.s4 * 2,
      reason:
          'the header padding and the attachment padding, and nothing '
          'between them: a blank line here reads as a rendering fault',
    );
    expect(
      find.byType(MessageBody),
      findsNothing,
      reason: 'there is no text to lay out, so there is nothing to build',
    );
  });

  testWidgets('a caption still gets its body, and its line back', (
    tester,
  ) async {
    await tester.pumpWidget(_row('look at this'));
    await tester.pump();

    // Pins the measurement itself: if the gap did not move with the body, the
    // test above would pass on a row that never had one to lose.
    expect(find.byType(MessageBody), findsOneWidget);
    final body = tester.getSize(find.byType(MessageBody)).height;
    expect(body, greaterThan(0));
    expect(_gapBelowHeader(tester), AppSpacing.s4 * 2 + body);
  });
}
