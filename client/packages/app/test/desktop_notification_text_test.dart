// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/desktop_notification_text.dart';

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
}
