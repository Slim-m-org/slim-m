// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows the UI snapshot matrix's fake server answers with: real members,
/// real presence, real roles, real invites, real reports, and a channel with
/// a real topic.
///
/// Split out of `ui_snapshot_support.dart` purely to stay under this repo's
/// line budget; see that file for the container and router this data feeds.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;

import 'ui_snapshot_dock.dart' show dockFixtureBody;

/// The members every surface can see, one of them with the longest display
/// name the server allows (64 characters is the real ceiling; this sits
/// close to it) so a row that only ever renders "Nick" and "Ada Lovelace"
/// cannot hide a label that fails to wrap or ellipsize.
const _fixtureMemberMaps = [
  {
    'id': 'user-nick',
    'username': 'nick',
    'display_name': 'Nick',
    'created_at': 0,
    'roles': ['admin'],
  },
  {
    'id': 'user-ada',
    'username': 'ada',
    'display_name': 'Ada Lovelace',
    'created_at': 0,
    'roles': <String>[],
  },
  {
    'id': 'user-long-name',
    'username': 'christoph',
    'display_name': 'Christoph Bartholomew Fitzgerald-Huang III',
    'created_at': 0,
    'roles': <String>[],
  },
];

/// Every role a deployment can actually have plus the worst-case name a role
/// editor has to render: bootstrap always seeds `@everyone` and one admin
/// role, so a roles screen rendered against an empty list (the previous
/// fixture) was a state the server cannot produce.
const _fixtureRoleMaps = [
  {
    'id': 'role-everyone',
    'name': '@everyone',
    // View + send only; bit 0 (administrator) unset, or this reads as a second all-access role.
    'permissions': 6,
    'is_everyone': true,
    'created_at': 0,
  },
  {
    'id': 'role-admin',
    'name': 'admin',
    'permissions': -1,
    'is_everyone': false,
    'created_at': 0,
  },
  {
    'id': 'role-longname',
    'name': 'Senior Community Trust and Safety Moderation Lead Emeritus',
    'permissions': 0,
    'is_everyone': false,
    'created_at': 0,
  },
];

/// Presence for the fixture roster: only the signed-in user online. Ada and
/// the long-name member are left unseeded (offline), which is what
/// `shell_semantics_test.dart` already asserts by name, and is enough on its
/// own to put a real screenshot's own Online and Offline groups both on
/// screen instead of leaving every member - self included - unseeded and
/// therefore Offline.
const _fixturePresenceMaps = [
  {'user_id': 'user-nick', 'status': 'online'},
];

/// A spent code (used up, not revoked, never expiring), a live one that
/// grants a role, and a revoked one: the three states the invite list badge
/// has to tell apart, none of which an empty list ever exercised.
const _fixtureInviteMaps = [
  {
    'code': 'AB12CD34EF',
    'max_uses': 10,
    'uses': 10,
    'expires_at': null,
    'created_at': 0,
    'revoked': false,
    'usable': false,
    'role_grant': null,
  },
  {
    'code': 'GH56IJ78KL',
    'max_uses': null,
    'uses': 3,
    'expires_at': 1758600000000,
    'created_at': 0,
    'revoked': false,
    'usable': true,
    'role_grant': 'role-longname',
  },
  {
    'code': 'MN90OP12QR',
    'max_uses': 5,
    'uses': 1,
    'expires_at': null,
    'created_at': 0,
    'revoked': true,
    'usable': false,
    'role_grant': null,
  },
];

/// A user report and a message report, one of each kind the queue renders,
/// with a reason long enough to show whether it is clamped and a snapshot
/// long enough to prove the clamp that already exists on it.
const _fixtureReportMaps = [
  {
    'id': 'report-1',
    'reporter_id': 'user-ada',
    'subject_kind': 'user',
    'subject_id': 'user-long-name',
    'channel_id': null,
    'reason':
        'Keeps derailing #design with off-topic links after being asked '
        'twice to stop.',
    'snapshot': null,
    'subject_author_id': null,
    'created_at': 1753600300000,
  },
  {
    'id': 'report-2',
    'reporter_id': 'user-long-name',
    'subject_kind': 'message',
    'subject_id': 'm-report-2',
    'channel_id': 'c-general',
    'reason':
        'This message names a real address and asks people to show up '
        'uninvited; it reads like harassment rather than a joke, and the '
        'poster has done this before in #general.',
    'snapshot':
        'Ok so hear me out, everyone should just go knock on their door at '
        '3am and film it for the channel, it will be hilarious and nobody '
        'will mind at all, trust me, I have done this before and it always '
        'goes great, and honestly if they get upset about it that is kind '
        'of on them for being home at 3am in the first place, worst case we '
        'just say it was a prank and apologize after the fact.',
    'subject_author_id': 'user-ada',
    'created_at': 1753600400000,
  },
];

/// One removal with a stated reason and one without, the two shapes
/// `RemovedMembersScreen`'s own card renders differently.
const _fixtureRemovalMaps = [
  {
    'user_id': 'user-removed-1',
    'username': 'grace',
    'display_name': 'Grace Hopper',
    'removed_at': 1753600500000,
    'reason': 'Posted an invite link to another, unrelated Space.',
    'removed_by': 'user-nick',
  },
  {
    'user_id': 'user-removed-2',
    'username': 'alan',
    'display_name': 'Alan Turing',
    'removed_at': 1753600600000,
    'reason': null,
    'removed_by': 'user-nick',
  },
];

/// A day, an active hour and a memory sample, enough for the analytics
/// screen's three charts to each render their populated shape rather than
/// their empty one, when a caller explicitly asks for the enabled answer.
const fixtureAnalyticsEnabled = {
  'enabled': true,
  'stats': {
    'total_messages': 812,
    'member_count': 3,
    'channel_count': 4,
    'attachment_bytes': 15728640,
    'messages_by_day': [
      {'date': '2026-08-06', 'count': 40},
      {'date': '2026-08-07', 'count': 12},
      {'date': '2026-08-08', 'count': 65},
    ],
    'active_hours': [
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      3,
      8,
      12,
      15,
      20,
      22,
      18,
      14,
      10,
      9,
      11,
      14,
      16,
      10,
      5,
      2,
      1,
    ],
    'memory_samples': [
      {'sampled_at': 1753600000000, 'rss_bytes': 9216000},
      {'sampled_at': 1753603600000, 'rss_bytes': 12400000},
      {'sampled_at': 1753607200000, 'rss_bytes': 11800000},
    ],
  },
};

/// Answers the reads the shell makes on its way up: the caller, the member
/// list, pins and a window of messages, plus the administration screens'
/// own lists.
///
/// A plain top-level function rather than only a [MockClient] closure, so a
/// surface needing one bespoke answer can build its own client that checks
/// its own path first and falls back to this for everything else, rather
/// than re-deriving the whole switch.
Future<http.Response> fixtureResponse(http.Request request) async {
  final path = request.url.path;
  // 404 like a real server: the catch-all `[]` renders as a blank disc.
  if (path.endsWith('/avatar')) return http.Response('', 404);

  final Object body = switch (path) {
    _ when dockFixtureBody(path) != null => dockFixtureBody(path)!,
    '/me' => {
      'id': 'user-nick',
      'username': 'nick',
      'display_name': 'Nick',
      'created_at': 0,
      'permissions': -1,
    },
    // The batch profile fetch a report card resolves its names through.
    '/users' => _fixtureMemberMaps,
    _ when path.endsWith('/members') => _fixtureMemberMaps,
    '/members/removed' => _fixtureRemovalMaps,
    _ when path == '/presence' && request.method == 'GET' =>
      _fixturePresenceMaps,
    '/roles' => _fixtureRoleMaps,
    '/invites' => _fixtureInviteMaps,
    '/reports' => _fixtureReportMaps,
    '/saved' => _fixtureSavedMaps,
    // A list is the right empty answer for most reads; the read marker decodes a shape.
    _ when path.endsWith('/read') => const {'last_read_seq': 3, 'unread': 0},
    _ when path.endsWith('/voice/roster') => const {'participants': <Object>[]},
    _ when path.endsWith('/thread-parent') => const {
      'parent_channel_id': null,
      'parent_channel_name': null,
      'parent_message_id': null,
    },
    _ when path.endsWith('/canvas/objects') => const {
      'objects': <Object>[],
      'has_more': false,
      'latest_seq': 0,
    },
    _ when path.endsWith('/canvas/ops') => {
      'ops': <Object>[],
      'latest_seq': int.parse(request.url.queryParameters['after_seq'] ?? '0'),
      'has_more': false,
      'reset': false,
    },
    _ when path.endsWith('/canvas/media-slots') => const {'slots': <Object>[]},
    _ when path.endsWith('/object-locks') => const {'object_ids': <String>[]},
    _ when path.contains('/canvas/media-slots/') => const {
      'kind': 'camera',
      'user_id': 'user-nick',
      'x': 0.0,
      'y': 0.0,
      'w': 1.0,
      'h': 1.0,
      'locked': false,
      'sent_to_back': false,
      'updated_at': 0,
    },
    '/space/settings' => const {'join_policy': 'invite'},
    // Off is this feature's real default; see docs/decisions/0008-space-analytics.md.
    '/space/analytics' => const {'enabled': false},
    _ => const <Object>[],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// Two saved messages from different channels, which is the shape the sheet
/// exists to render: a saved list spans channels, so each row has to say
/// where it came from.
final _fixtureSavedMaps = [
  {
    'id': 'm-2',
    'channel_id': 'c-design',
    'author_id': 'user-ada',
    'author_display_name': 'Ada Lovelace',
    'seq': 2,
    'content': 'The spacing on the settings pane is off by a hair at 800.',
    'created_at': 1753600000000,
    'edited_at': null,
    'saved_at': 1753600500000,
  },
  {
    'id': 'm-1',
    'channel_id': 'c-general',
    'author_id': 'user-nick',
    'author_display_name': 'Nick',
    'seq': 1,
    'content': 'The rail rows line up again at every width.',
    'created_at': 1753600060000,
    'edited_at': null,
    'saved_at': 1753600400000,
  },
];

MockClient fixtureClient() => MockClient(fixtureResponse);

/// The two categories the backfill (migration 0031) would have created for
/// any pre-existing deployment: see docs/decisions/0006-channel-categories.md.
const fixtureCategories = [
  api.ChannelCategory(id: 'cat-text', name: 'Text', position: 0, createdAt: 0),
  api.ChannelCategory(
    id: 'cat-voice',
    name: 'Voice',
    position: 1,
    createdAt: 0,
  ),
];

const fixtureChannels = [
  api.Channel(
    id: 'c-general',
    name: 'general',
    kind: 'text',
    createdAt: 0,
    categoryId: 'cat-text',
    topic:
        'General chat for the whole Space - keep it friendly, and keep '
        'call logistics in #main instead of here.',
  ),
  api.Channel(
    id: 'c-design',
    name: 'design',
    kind: 'text',
    createdAt: 0,
    categoryId: 'cat-text',
    topic: 'tokens, type and the shell',
  ),
  api.Channel(
    id: 'c-main',
    name: 'main',
    kind: 'voice',
    createdAt: 0,
    categoryId: 'cat-voice',
    joinMuted: true,
  ),
  // A thread's own channel row, hanging off m-1: the stacked-header render.
  api.Channel(
    id: 'c-thread',
    name: '',
    kind: 'text',
    createdAt: 0,
    parentMessageId: 'm-1',
  ),
  // An ordinary DM: the rail's DM section, a DM transcript, and dm-call.
  api.Channel(
    id: 'c-dm-ada',
    name: 'Ada Lovelace',
    kind: 'dm',
    createdAt: 0,
    dmParticipantId: 'user-ada',
  ),
  // Empty and uncategorised: the transcript's three empty-ish states need it.
  api.Channel(id: 'c-empty', name: 'empty', kind: 'text', createdAt: 0),
];

api.Message _message(
  int seq,
  String author,
  String content, {
  List<api.ReactionSummary> reactions = const [],
  api.ForwardedMessage? forwarded,
}) => api.Message(
  id: 'm-$seq',
  channelId: 'c-general',
  authorId: author,
  authorDisplayName: author == 'user-nick' ? 'Nick' : 'Ada Lovelace',
  seq: seq,
  content: content,
  createdAt: 1753600000000 + seq * 60000,
  editedAt: null,
  reactions: reactions,
  forwarded: forwarded,
);

/// An origin in `c-design`, a channel this fixture's own list holds - so the
/// card resolves a location and renders its jump affordance. A forward whose
/// origin is missing from that list is the other branch, and is covered by
/// `forwarded_message_card_test.dart` rather than a viewport sweep.
const _forwardedOrigin = api.ForwardedMessage(
  messageId: 'm-2',
  channelId: 'c-design',
  authorId: 'user-ada',
  authorDisplayName: 'Ada Lovelace',
  authorAvatarUpdatedAt: null,
  createdAt: 1753600000000,
  content: 'The spacing on the settings pane is off by a hair at 800.',
);

/// A forward whose original was deleted: the server blanks the snapshot and
/// sets [removed], and the card says so in place of it.
const _removedForwardedOrigin = api.ForwardedMessage(
  messageId: 'm-2',
  channelId: 'c-design',
  authorId: null,
  authorDisplayName: null,
  authorAvatarUpdatedAt: null,
  createdAt: 1753600000000,
  content: '',
  removed: true,
);

/// A reply inside `c-thread`, the thread hanging off [_message]'s `m-1`.
api.Message _threadMessage(int seq, String author, String content) =>
    api.Message(
      id: 'mt-$seq',
      channelId: 'c-thread',
      authorId: author,
      authorDisplayName: author == 'user-nick' ? 'Nick' : 'Ada Lovelace',
      seq: seq,
      content: content,
      createdAt: 1753600000000 + (100 + seq) * 60000,
      editedAt: null,
    );

/// A message inside `c-dm-ada`, the ordinary (non-personal-space) DM.
api.Message _dmMessage(int seq, String author, String content) => api.Message(
  id: 'mdm-$seq',
  channelId: 'c-dm-ada',
  authorId: author,
  authorDisplayName: author == 'user-nick' ? 'Nick' : 'Ada Lovelace',
  seq: seq,
  content: content,
  createdAt: 1753600000000 + (200 + seq) * 60000,
  editedAt: null,
);

final fixtureMessages = [
  _message(1, 'user-ada', 'The rail rows line up again at every width.'),
  _message(
    2,
    'user-nick',
    'Reactions render in colour now, not outlines.',
    reactions: const [
      api.ReactionSummary(emoji: '\u{1F389}', count: 2, reacted: true),
      api.ReactionSummary(emoji: '\u{2764}\u{FE0F}', count: 1, reacted: false),
    ],
  ),
  _message(
    3,
    'user-ada',
    'Long enough to wrap on a phone and prove the composer still clears '
        'the home indicator underneath it.',
  ),
  _message(
    4,
    'user-nick',
    'Worth a look here too.',
    forwarded: _forwardedOrigin,
  ),
  _message(
    5,
    'user-ada',
    'Passing this along with a note of my own.',
    forwarded: _removedForwardedOrigin,
  ),
  _threadMessage(1, 'user-ada', 'Good catch - filed as #341.'),
  _threadMessage(2, 'user-nick', 'Thanks, verifying the fix now.'),
  _dmMessage(1, 'user-ada', 'Got a minute to look at the overwrites screen?'),
  _dmMessage(2, 'user-nick', 'Yeah, pulling it up now.'),
];
