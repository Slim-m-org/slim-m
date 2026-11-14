// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A search hit found through an attachment's text says so, naming the file,
/// and a hit found through its own text does not. A voice message found through
/// its transcript shows what was said rather than its file name.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/messages/providers/message_search.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette_items.dart'
    show messageResultItem;

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

api.Message _voiceHit({String text = 'meet me at the lighthouse'}) =>
    api.Message.fromJson({
      'id': 'm2',
      'channel_id': 'c1',
      'author_id': 'u1',
      'author_display_name': 'Priya',
      'seq': 2,
      'content': '',
      'created_at': 1,
      'attachments': [
        {
          'id': 'v1',
          'filename': 'voice-message.ogg',
          'content_type': 'audio/ogg',
          'size': 10,
          'voice': true,
          'duration_ms': 4000,
          'waveform': List.filled(64, 90),
          'transcript': {'status': 'ready', 'text': text},
        },
      ],
      'matched_attachment_id': 'v1',
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

  test('a voice hit gives its transcript, and any other hit none', () {
    expect(matchedVoiceTranscript(_voiceHit()), 'meet me at the lighthouse');
    expect(matchedVoiceTranscript(_voiceHit(text: '')), isNull);
    expect(matchedVoiceTranscript(_hit(matched: 'a1')), isNull);
    expect(matchedVoiceTranscript(_hit(content: 'hi')), isNull);
  });

  testWidgets('a voice hit shows what was said, not the file name', (
    tester,
  ) async {
    await _pump(tester, _voiceHit());
    expect(find.text('meet me at the lighthouse'), findsOneWidget);
    expect(find.textContaining('voice-message.ogg'), findsNothing);
    expect(find.text('Found in a voice message'), findsOneWidget);
  });

  test('the palette labels a voice hit with what was said', () {
    final item = messageResultItem(
      _voiceHit(),
      channelLabel: '#general',
      onSelect: (_, __) async {},
    );
    expect(item.label, 'meet me at the lighthouse');
  });
}
