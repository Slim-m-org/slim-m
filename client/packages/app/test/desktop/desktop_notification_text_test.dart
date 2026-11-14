// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/providers/desktop_notification_text.dart';
import 'package:slimm_app/src/features/messages/widgets/message_inline.dart'
    show rewriteMentions;

api.Message _message(
  String content, {
  String? author = 'Ada',
  List<api.Attachment> attachments = const [],
}) => api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'u1',
  authorDisplayName: author,
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
  attachments: attachments,
);

const _image = api.Attachment(
  id: 'a1',
  filename: 'cat.png',
  contentType: 'image/png',
  size: 10,
);

void main() {
  test(
    'a channel message names the author and channel, and shows the text',
    () {
      final text = desktopNotificationText(
        _message('lunch at **noon**?'),
        showText: true,
        isDm: false,
        channelName: 'general',
      );
      expect(text.title, 'Ada in #general');
      expect(text.body, 'lunch at noon?');
    },
  );

  test('a DM names only the author', () {
    final text = desktopNotificationText(
      _message('hey'),
      showText: true,
      isDm: true,
      channelName: 'ignored',
    );
    expect(text.title, 'Ada');
    expect(text.body, 'hey');
  });

  test('a spoiler stays hidden', () {
    final text = desktopNotificationText(
      _message('the ending: ||he was the ghost||'),
      showText: true,
      isDm: false,
      channelName: 'movies',
    );
    expect(text.body, isNot(contains('ghost')));
    expect(text.body, contains('[spoiler]'));
  });

  test('an attachment-only message says what it sent', () {
    final text = desktopNotificationText(
      _message('', attachments: const [_image]),
      showText: true,
      isDm: false,
      channelName: 'general',
    );
    expect(text.body, 'Photo');
  });

  test('a voice message says so, and another audio file names itself', () {
    String body(api.Attachment attachment) => desktopNotificationText(
      _message('', attachments: [attachment]),
      showText: true,
      isDm: true,
    ).body;
    expect(
      body(
        api.Attachment(
          id: 'v',
          filename: 'voice-message.wav',
          contentType: 'audio/wav',
          size: 4,
          voice: api.VoiceInfo(
            duration: const Duration(seconds: 3),
            waveform: List.filled(64, 0),
          ),
        ),
      ),
      'Voice message',
    );
    expect(
      body(
        const api.Attachment(
          id: 's',
          filename: 'song.mp3',
          contentType: 'audio/mpeg',
          size: 4,
        ),
      ),
      'song.mp3',
    );
  });

  test('long text is cut on a rune boundary', () {
    final text = desktopNotificationText(
      _message('\u{1F600}' * 300),
      showText: true,
      isDm: true,
    );
    expect(text.body.runes.length, desktopNotificationMaxRunes + 1);
    expect(text.body.endsWith('…'), isTrue);
  });

  test('with text off, the body only names the author', () {
    final text = desktopNotificationText(
      _message('secret plans'),
      showText: false,
      isDm: false,
      channelName: 'general',
    );
    expect(text.title, isNull);
    expect(text.body, 'New message from Ada');
  });

  test('no author to name falls back to a bare line', () {
    final text = desktopNotificationText(
      _message('hi', author: null),
      showText: true,
      isDm: false,
      channelName: 'general',
    );
    expect(text.body, 'New message');
  });

  group('mention names', () {
    const names = {'ada': 'Countess Ada'};

    String body(String content) => desktopNotificationText(
      _message(content),
      showText: true,
      isDm: false,
      mentionNames: names,
    ).body;

    test('a mention reads as the name in this space', () {
      expect(body('hi @Ada, and @ghost.'), 'hi @Countess Ada, and @ghost.');
    });

    test('code, fences and escapes keep the username', () {
      expect(body('`@ada` \\@ada'), '@ada @ada');
      expect(
        rewriteMentions('```\n@ada\n```\nthen @ada', names),
        '```\n@ada\n```\nthen @Countess Ada',
      );
    });

    test('with no names the text is untouched', () {
      final text = desktopNotificationText(
        _message('hi @ada'),
        showText: true,
        isDm: false,
      );
      expect(text.body, 'hi @ada');
    });
  });
}
