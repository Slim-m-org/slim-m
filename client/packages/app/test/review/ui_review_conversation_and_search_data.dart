// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The seeded conversation the conversation-and-search review suites share: a
/// long transcript to scroll, the wire shapes the sheets and search read, and
/// the extra channels an inbox needs.
library;

import 'package:slimm_api/api.dart' as api;

import '../ui_snapshot_fixture_data.dart' show fixtureMessages;

const _nick = 'user-nick';
const _ada = 'user-ada';
const _christoph = 'user-long-name';

const _names = {
  _nick: 'Nick',
  _ada: 'Ada Lovelace',
  _christoph: 'Christoph Bartholomew Fitzgerald-Huang III',
};

/// What a Space talks about on a Tuesday: short, long, code and a link, from all three authors.
const _lines = <(String, String)>[
  (_ada, 'Pushed the rail spacing fix. Can someone check it at 1280?'),
  (_nick, 'Looking now. Category headers sit one row apart again, thanks.'),
  (
    _christoph,
    'Reminder that the release branch freezes at 17:00 UTC, so anything for '
        '0.128 has to be merged before then. Ping me if a review is blocking you.',
  ),
  (
    _ada,
    'The topic text still truncates mid-word on the phone, filing it now.',
  ),
  (_nick, 'Use `AppText.caption` there, the body size is what clips it.'),
  (
    _ada,
    'Makes sense. Is the **Threads** sheet meant to show unread dots too?',
  ),
  (_nick, 'Yes, same dot the message row uses.'),
  (
    _christoph,
    'Link for the design review notes: https://example.com/design/review-2026-11',
  ),
  (_ada, 'Thanks. I will read them before standup.'),
  (_nick, 'Anyone seen the call audio drop on the Linux build this morning?'),
  (_ada, 'Not here. Which device was it on?'),
  (_nick, 'The USB headset. It came back after I replugged it.'),
  (
    _christoph,
    'That is the same pattern as last week, I will add it to the notes so we '
        'stop rediscovering it every Tuesday.',
  ),
  (_ada, 'Sounds good.'),
  (
    _nick,
    'Small thing: the composer hint still says "Message #general" on DMs.',
  ),
  (_ada, 'That one is fixed on main, it ships with the next build.'),
  (_nick, 'Great.'),
  (
    _christoph,
    'Quick poll for the retro: do we keep the Friday demo slot or move it to '
        'Thursday afternoon so the west coast can join live?',
  ),
  (_ada, 'Thursday works better for me.'),
  (_nick, 'Same. Friday afternoons are always half empty.'),
  (_ada, 'I will update the calendar invite.'),
  (_christoph, 'Thank you both. Moving it from next week.'),
  (_nick, 'While you are in there, can the invite carry the canvas link?'),
  (_ada, 'Done.'),
  (_nick, 'Perfect, that is everything from me for today.'),
  (_ada, 'One last thing: the screenshots for the review are in the thread.'),
  (_christoph, 'Seen them, they look right to me.'),
  (_nick, 'Same here. Shipping it.'),
  (_ada, 'Merged.'),
  (_christoph, 'Thanks all. Closing the review.'),
];

/// Messages 6..[upTo] of #general, after the five the shared fixture already seeds.
List<api.Message> longTranscript({int upTo = 35}) => [
  for (var seq = 6; seq <= upTo; seq++) _generalMessage(seq),
];

api.Message _generalMessage(int seq) {
  final (author, content) = _lines[(seq - 6) % _lines.length];
  return api.Message(
    id: 'm-$seq',
    channelId: 'c-general',
    authorId: author,
    authorDisplayName: _names[author],
    seq: seq,
    content: content,
    createdAt: 1753600000000 + seq * 60000,
    editedAt: null,
  );
}

/// The shared fixture's five #general messages followed by the long transcript.
List<api.Message> fullTranscript() => [...fixtureMessages, ...longTranscript()];

/// A few voice-channel chat lines, so the phone's "Back to call" chat is not empty.
List<api.Message> voiceChat() => [
  for (var seq = 1; seq <= 4; seq++)
    api.Message(
      id: 'mv-$seq',
      channelId: 'c-main',
      authorId: seq.isEven ? _nick : _ada,
      authorDisplayName: seq.isEven ? 'Nick' : 'Ada Lovelace',
      seq: seq,
      content: const [
        'Can you hear me now?',
        'Loud and clear.',
        'Sharing my screen in a second, the build is red again.',
        'Got it, I see the failing job.',
      ][seq - 1],
      createdAt: 1753600000000 + seq * 60000,
      editedAt: null,
    ),
];

Map<String, Object?> messageJson(api.Message m, {Map<String, Object?>? more}) =>
    {
      'id': m.id,
      'channel_id': m.channelId,
      'author_id': m.authorId,
      'author_display_name': m.authorDisplayName,
      'seq': m.seq,
      'content': m.content,
      'created_at': m.createdAt,
      'edited_at': null,
      ...?more,
    };

/// Pins in newest-pin-first order, drawn from the seeded transcript.
List<Map<String, Object?>> pinsJson() => [
  for (final (i, seq) in const [8, 13, 18].indexed)
    messageJson(
      _generalMessage(seq),
      more: {'pinned_at': 1753700000000 - i * 3600000, 'pinned_by': _nick},
    ),
];

List<Map<String, Object?>> threadsJson() => [
  {
    'id': 'c-thread',
    'parent_message_id': 'm-1',
    'parent_content': 'The rail rows line up again at every width.',
    'parent_author_id': _ada,
    'parent_author_display_name': 'Ada Lovelace',
    'created_at': 1753600000000,
    'reply_count': 12,
    'last_reply_at': 1753700000000,
    'unread_count': 3,
  },
  {
    'id': 'c-thread-2',
    'parent_message_id': 'm-8',
    'parent_content':
        'Link for the design review notes: https://example.com/design/review-2026-11',
    'parent_author_id': _christoph,
    'parent_author_display_name': _names[_christoph],
    'created_at': 1753601000000,
    'reply_count': 1,
    'last_reply_at': 1753650000000,
    'unread_count': 0,
  },
  {
    'id': 'c-thread-3',
    'parent_message_id': 'm-18',
    'parent_content':
        'Quick poll for the retro: do we keep the Friday demo slot or move it '
        'to Thursday afternoon so the west coast can join live?',
    'parent_author_id': _christoph,
    'parent_author_display_name': _names[_christoph],
    'created_at': 1753602000000,
    'reply_count': 27,
    'last_reply_at': 1753690000000,
    'unread_count': 0,
  },
];

/// What the saved sheet lists: several channels, a long author name, and one very long line.
List<Map<String, Object?>> savedJson() => [
  for (final (i, m) in [
    (_generalMessage(8), 'c-general'),
    (_generalMessage(13), 'c-general'),
    (
      const api.Message(
        id: 'm-saved-design',
        channelId: 'c-design',
        authorId: _ada,
        authorDisplayName: 'Ada Lovelace',
        seq: 2,
        content:
            'The spacing on the settings pane is off by a hair at 800, and the '
            'section headers need another four pixels above them so the cards '
            'stop reading as one block when the window is narrow.',
        createdAt: 1753600000000,
        editedAt: null,
      ),
      'c-design',
    ),
  ].indexed)
    messageJson(
      m.$1,
      more: {'channel_id': m.$2, 'saved_at': 1753700000000 - i * 60000},
    ),
];

/// Hits for "release": the same word in different lines, one by a long-named author.
List<Map<String, Object?>> releaseHits() => [
  messageJson(_generalMessage(8)),
  messageJson(
    _hit(
      21,
      _nick,
      'Can we cut the release candidate before standup? I will write the notes.',
    ),
  ),
  messageJson(
    _hit(33, _ada, 'Release notes draft is in the thread, comments welcome.'),
  ),
];

api.Message _hit(int seq, String author, String content) => api.Message(
  id: 'm-$seq',
  channelId: 'c-general',
  authorId: author,
  authorDisplayName: _names[author],
  seq: seq,
  content: content,
  createdAt: 1753600000000 + seq * 60000,
  editedAt: null,
);

/// Channels beyond the shared fixture's, for the inbox and the palette.
const extraChannels = [
  api.Channel(
    id: 'c-releases',
    name: 'releases',
    kind: 'text',
    createdAt: 5,
    categoryId: 'cat-text',
  ),
  api.Channel(
    id: 'c-bugs',
    name: 'bug-reports',
    kind: 'text',
    createdAt: 6,
    categoryId: 'cat-text',
  ),
  api.Channel(
    id: 'c-announce',
    name: 'announcements',
    kind: 'text',
    createdAt: 7,
    categoryId: 'cat-text',
  ),
];
