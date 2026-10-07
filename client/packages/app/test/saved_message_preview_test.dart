// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/widgets/saved_messages_sheet.dart';

import 'message_row_harness.dart';

api.Message _msg(
  String id,
  String content, [
  List<api.Attachment> attachments = const [],
]) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'a1',
  authorDisplayName: 'Priya',
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
  attachments: attachments,
);

Future<void> _pump(WidgetTester tester, api.Message m) async {
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox())],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    harness(
      SavedMessageRow(
        saved: api.SavedMessage(message: m, savedAt: 0),
        router: router,
        currentChannelId: 'c1',
      ),
      overrides: [
        channelByIdProvider('c1').overrideWith((ref) => Stream.value(null)),
      ],
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a fenced code block is flattened like the reply banner does', (
    tester,
  ) async {
    await _pump(tester, _msg('m1', '```dart\nprint(1);\n```'));
    expect(
      find.textContaining('```'),
      findsNothing,
      reason: 'raw fence markers are shown in the saved row',
    );
  });

  testWidgets('an image-only save is named, not blank', (tester) async {
    await _pump(
      tester,
      _msg('m2', '', const [
        api.Attachment(
          id: 'h',
          filename: 'x.png',
          contentType: 'image/png',
          size: 1,
        ),
      ]),
    );
    expect(
      find.text('Photo'),
      findsOneWidget,
      reason: 'attachment-only saved message has a blank subtitle',
    );
  });
}
