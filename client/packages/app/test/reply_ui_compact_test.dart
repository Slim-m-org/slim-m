// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staged-reply banner and the in-transcript reply reference, measured.
///
/// The banner is one compact row (`docs/design/desktop-vs-mobile.md` law 2:
/// 30dp pointer rows, 44dp touch rows), and a reply to an attachment-only
/// message names what it carried with a thumbnail or kind glyph instead of
/// "(no text)".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/reply_banner.dart';
import 'package:slimm_data/data.dart';

import 'message_row_harness.dart';

const _thumb = ValueKey('reply-attachment-thumb');

api.Attachment _att(String id, String name, String type) =>
    api.Attachment(id: id, filename: name, contentType: type, size: 1024);

final _targets = <String, List<api.Attachment>>{
  'image': [_att('a1', 'IMG_1362.jpeg', 'image/jpeg')],
  'video': [_att('a2', 'clip.mp4', 'video/mp4')],
  'file': [_att('a3', 'report.pdf', 'application/pdf')],
  'voice': [_att('a4', 'voice.ogg', 'audio/ogg')],
};

List<Override> _carrying(List<api.Attachment> attachments) => [
  liveEventsProvider.overrideWithValue(const Stream<api.ServerEvent>.empty()),
  messageExtrasProvider.overrideWith((ref) {
    final controller = MessageExtrasController(ref);
    controller.applyMessage(
      api.Message(
        id: 'p',
        channelId: 'c1',
        authorId: 'author-1',
        authorDisplayName: 'Nadia',
        seq: 1,
        content: '',
        createdAt: 0,
        editedAt: null,
        attachments: attachments,
      ),
    );
    return controller;
  }),
];

Future<void> _size(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _top(Widget child) =>
    Align(alignment: Alignment.topCenter, child: child);

void main() {
  for (final entry in _targets.entries) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('banner for a ${entry.key} parent is one compact row at '
          '${width.toInt()}', (tester) async {
        await _size(tester, width);
        await tester.pumpWidget(
          harness(
            _top(
              ReplyBanner(
                message: message(
                  id: 'p',
                  authorDisplayName: 'Nadia',
                  content: '',
                ),
                onCancel: () {},
              ),
            ),
            overrides: _carrying(entry.value),
          ),
        );
        await tester.pump();
        final height = tester.getSize(find.byType(ReplyBanner)).height;
        // 44dp touch row plus a 4dp gutter on a phone; 30dp plus 4 on desktop.
        expect(height, lessThanOrEqualTo(width < 600 ? 48 : 34));
        expect(find.text('(no text)'), findsNothing);
        expect(find.byKey(_thumb), findsOneWidget);
        final close = tester.getSize(find.byTooltip('Cancel reply').first);
        if (width < 600) expect(close.shortestSide, greaterThanOrEqualTo(44));
      });

      testWidgets('quote of a ${entry.key} parent shows its kind at '
          '${width.toInt()}', (tester) async {
        await _size(tester, width);
        final parent = message(
          id: 'p',
          authorDisplayName: 'Nadia',
          content: '',
        );
        await tester.pumpWidget(
          harness(
            MessageRow(
              message: const Message(
                id: 'r',
                channelId: 'c1',
                authorId: 'author-2',
                authorDisplayName: 'Nick',
                seq: 2,
                content: 'reply',
                createdAt: 1,
                replyToId: 'p',
                pending: false,
                failed: false,
              ),
              grouped: false,
              showNewDivider: false,
              knownUsernames: const {},
              actions: noActions,
              editing: false,
              replyTo: parent,
              callbacks: MessageRowCallbacks(
                onRetry: noop,
                onDiscard: noop,
                onPickReaction: (_) {},
                onReactionTap: (_) {},
                onVote: (_) {},
                onSubmitEdit: (_) {},
                onCancelEdit: noop,
                onReplyTap: noop,
              ),
            ),
            overrides: _carrying(entry.value),
          ),
        );
        await tester.pump();
        expect(find.textContaining('(no text)'), findsNothing);
        expect(find.byKey(_thumb), findsOneWidget);
      });
    }
  }
}
