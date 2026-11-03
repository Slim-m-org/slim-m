// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A card that ends a message leaves the next row at least the room a line of
/// text leaves under its baseline, so the next row's highlight never touches it.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart'
    show MessageExtras;
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/features/messages/widgets/embed_card.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';

import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'message_row_harness.dart';

const _url = 'https://example.com/story';
const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

class _Case {
  const _Case(this.name, this.content, this.extras, this.card);

  final String name;
  final String content;
  final MessageExtras extras;
  final bool Function(Widget) card;
}

final _cases = [
  _Case(
    'embed',
    '',
    const MessageExtras(
      embeds: [api.Embed(title: 'Headline', footerText: 'feed')],
    ),
    (w) => w is EmbedCard,
  ),
  _Case(
    'link preview',
    _url,
    const MessageExtras(),
    (w) =>
        w is GestureDetector &&
        w.onTap != null &&
        w.child is SelectionContainer,
  ),
  _Case(
    'file attachment',
    '',
    const MessageExtras(
      attachments: [
        api.Attachment(
          id: 'doc',
          filename: 'notes.pdf',
          contentType: 'application/pdf',
          size: 2048,
        ),
      ],
    ),
    (w) => w is AttachmentView,
  ),
  _Case(
    'image attachment',
    '',
    const MessageExtras(
      attachments: [
        api.Attachment(
          id: 'img',
          filename: 'photo.png',
          contentType: 'image/png',
          size: 4,
        ),
      ],
    ),
    (w) => w is AttachmentView,
  ),
];

MessageRow _row(
  String id,
  bool grouped,
  String content,
  MessageExtras extras,
) => MessageRow(
  key: ValueKey(id),
  message: message(id: id, content: content),
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
  extras: extras,
);

Future<void> _pump(WidgetTester tester, _Case c, bool nextGrouped) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    harness(
      ListView(
        children: [
          _row('a', false, c.content, c.extras),
          _row('b', nextGrouped, 'next', const MessageExtras()),
        ],
      ),
      overrides: [
        linkPreviewProvider(_url).overrideWith(
          (ref) async => const api.LinkPreview(
            url: _url,
            title: 'Story',
            siteName: 'Example',
          ),
        ),
        attachmentBytesProvider(
          'img',
        ).overrideWith((ref) async => Uint8List.fromList(_png)),
        attachmentPreviewBytesProvider.overrideWith(
          (ref, key) async => Uint8List.fromList(_png),
        ),
      ],
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a text line leaves room under its baseline', (tester) async {
    await _pump(
      tester,
      _Case('text', 'hello there', const MessageExtras(), (_) => false),
      false,
    );
    expect(_textSlack(tester, 'hello there'), greaterThan(0));
  });

  for (final c in _cases) {
    for (final grouped in [false, true]) {
      testWidgets(
        'a ${c.name} leaves the next ${grouped ? 'grouped' : 'headed'} row clear',
        (tester) async {
          await _pump(
            tester,
            _Case('text', 'hello there', const MessageExtras(), (_) => false),
            grouped,
          );
          final reference = _textSlack(tester, 'hello there');

          await _pump(tester, c, grouped);
          final card = tester.getRect(find.byWidgetPredicate(c.card).first);
          final next = tester.getRect(find.byKey(const ValueKey('b')));
          expect(next.top - card.bottom, greaterThan(0));
          expect(next.top - card.bottom, greaterThanOrEqualTo(reference));
        },
      );
    }
  }
}

double _textSlack(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final box = tester.getRect(find.text(text));
  final baseline = paragraph.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  final next = tester.getRect(find.byKey(const ValueKey('b')));
  return next.top - (box.top + baseline);
}
