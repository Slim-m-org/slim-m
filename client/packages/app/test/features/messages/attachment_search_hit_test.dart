// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A search hit found through an attachment's text says so, naming the file,
/// and a hit found through its own text does not.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/messages/providers/message_search.dart';

import 'message_row_harness.dart';

api.Message _hit({String content = '', String? matched}) =>
    api.Message.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'author_id': 'u1',
      'author_display_name': 'Priya',
      'seq': 1,
      'content': content,
      'created_at': 1,
      'attachments': [
        {
          'id': 'a1',
          'filename': 'notes.txt',
          'content_type': 'text/plain',
          'size': 10,
        },
      ],
      if (matched != null) 'matched_attachment_id': matched,
    });

Future<void> _pump(WidgetTester tester, api.Message message) =>
    tester.pumpWidget(
      harness(
        SearchResultRow(
          message: message,
          knownUsernames: const {},
          customEmoji: const {},
          onSelect: (_) {},
        ),
      ),
    );

void main() {
  test(
    'the matched file is named, with a fallback and none for a text hit',
    () {
      expect(matchedAttachmentName(_hit(matched: 'a1')), 'notes.txt');
      expect(matchedAttachmentName(_hit(matched: 'gone')), 'an attachment');
      expect(matchedAttachmentName(_hit(content: 'hi')), isNull);
    },
  );

  testWidgets('an attachment hit says which file it was found in', (
    tester,
  ) async {
    await _pump(tester, _hit(matched: 'a1'));
    expect(find.text('Found in notes.txt'), findsOneWidget);
  });

  testWidgets('a hit on the message text carries no file line', (tester) async {
    await _pump(tester, _hit(content: 'hello'));
    expect(find.textContaining('Found in'), findsNothing);
  });
}
