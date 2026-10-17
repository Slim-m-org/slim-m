// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the routes and wire-shape changes this package just picked up:
/// presence, direct messages, pins, polls, attachments and avatars, the
/// invite-check community preview, the server identity on `Version`, and the
/// WebSocket frames that ride along with all of it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'user-1',
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      accessExpiresAt: 0,
    );

Map<String, dynamic> _messageJson({
  List<Map<String, dynamic>>? reactions,
  Map<String, dynamic>? poll,
  List<Map<String, dynamic>>? attachments,
  bool? mentionsMe,
}) =>
    {
      'id': 'm',
      'channel_id': 'c',
      'author_id': 'u',
      'seq': 1,
      'content': 'hi',
      'created_at': 1,
      'edited_at': null,
      if (reactions != null) 'reactions': reactions,
      if (poll != null) 'poll': poll,
      if (attachments != null) 'attachments': attachments,
      if (mentionsMe != null) 'mentions_me': mentionsMe,
    };

void main() {
  group('Version.identity', () {
    test('an older server omitting identity parses without error', () {
      final version = Version.fromJson({
        'name': 'slim-m',
        'version': '0.9.0',
        'protocol': 1,
      });
      expect(version.identity, isNull);
    });

    test('identity parses byte-for-byte when present', () {
      final version = Version.fromJson({
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'identity': {
          'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'fingerprint': 'a' * 32,
          'fingerprint_groups': [
            'aaaa',
            'aaaa',
            'aaaa',
            'aaaa',
            'aaaa',
            'aaaa',
            'aaaa',
            'aaaa'
          ],
          'color_strip': [0, 1, 2, 3],
        },
      });
      expect(version.identity, isNotNull);
      expect(version.identity!.publicKey,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(version.identity!.fingerprint, 'a' * 32);
      expect(version.identity!.fingerprintGroups, hasLength(8));
      expect(version.identity!.colorStrip, [0, 1, 2, 3]);
    });
  });

  group('InviteCheck', () {
    test('the invalid branch carries no fields to mine', () {
      final check = InviteCheck.fromJson({'usable': false});
      expect(check, isA<InviteUnusable>());
      // The type itself is the guarantee: InviteUnusable has no community
      // field to read at all, so there is nothing to accidentally render.
      switch (check) {
        case InviteUnusable():
          break;
        case InviteUsable():
          fail('an unusable code must not parse as usable');
      }
    });

    test(
        'community metadata is reachable only after matching the usable '
        'branch', () {
      final check = InviteCheck.fromJson({
        'usable': true,
        'community': {
          'name': 'the friend group',
          'member_count': 12,
          'invited_by': 'nick',
          'uses_remaining': 3,
          'expires_at': 999,
        },
      });
      expect(check, isA<InviteUsable>());
      switch (check) {
        case InviteUsable(:final community):
          expect(community.name, 'the friend group');
          expect(community.memberCount, 12);
          expect(community.invitedBy, 'nick');
          expect(community.usesRemaining, 3);
          expect(community.expiresAt, 999);
        case InviteUnusable():
          fail('a usable code must parse as usable');
      }
    });

    test(
        'a deleted inviter or an unlimited/never-expiring invite reads as '
        'null, not a placeholder', () {
      final check = InviteCheck.fromJson({
        'usable': true,
        'community': {
          'name': 'the friend group',
          'member_count': 1,
          'invited_by': null,
          'uses_remaining': null,
          'expires_at': null,
        },
      });
      final usable = check as InviteUsable;
      expect(usable.community.invitedBy, isNull);
      expect(usable.community.usesRemaining, isNull);
      expect(usable.community.expiresAt, isNull);
    });
  });

  group('Message: reactions, poll, attachments', () {
    test('reactions are parsed with the viewer-specific reacted flag', () {
      final message = Message.fromJson(_messageJson(reactions: [
        // Escaped rather than literal: the hygiene gate forbids emoji
        // codepoints in client source. These are user content, not chrome.
        {'emoji': '\u{1F44D}', 'count': 3, 'reacted': true},
        {'emoji': '\u{1F389}', 'count': 1, 'reacted': false},
      ]));
      expect(message.reactions, hasLength(2));
      expect(message.reactions.first.emoji, '\u{1F44D}');
      expect(message.reactions.first.count, 3);
      expect(message.reactions.first.reacted, isTrue);
      expect(message.reactions.last.reacted, isFalse);
    });

    test('a message with no reactions key parses as an empty list, not null',
        () {
      final message = Message.fromJson(_messageJson());
      expect(message.reactions, isEmpty);
    });

    test(
        'mentionsMe parses per-viewer and defaults false when the key is absent',
        () {
      expect(Message.fromJson(_messageJson()).mentionsMe, isFalse);
      expect(
        Message.fromJson(_messageJson(mentionsMe: false)).mentionsMe,
        isFalse,
      );
      expect(
        Message.fromJson(_messageJson(mentionsMe: true)).mentionsMe,
        isTrue,
      );
    });

    test('a poll message carries its tally and the viewer\'s own vote', () {
      final message = Message.fromJson(_messageJson(poll: {
        'question': 'lunch?',
        'options': [
          {'position': 0, 'label': 'pizza', 'votes': 2},
          {'position': 1, 'label': 'salad', 'votes': 0},
        ],
        'total_votes': 2,
        'voted_option': 0,
        'close_at': null,
        'closed': false,
      }));
      expect(message.poll, isNotNull);
      expect(message.poll!.question, 'lunch?');
      expect(message.poll!.options, hasLength(2));
      expect(message.poll!.votedOption, 0);
      expect(message.poll!.closed, isFalse);
    });

    test('an ordinary message has a null poll, never a placeholder', () {
      final message = Message.fromJson(_messageJson());
      expect(message.poll, isNull);
    });

    test('attachments ride along on a freshly sent message', () {
      final message = Message.fromJson(_messageJson(attachments: [
        {
          'id': 'deadbeef',
          'filename': 'photo.png',
          'content_type': 'image/png',
          'size': 1024,
        },
      ]));
      expect(message.attachments, hasLength(1));
      expect(message.attachments.single.id, 'deadbeef');
      expect(message.attachments.single.filename, 'photo.png');
      expect(message.attachments.single.contentType, 'image/png');
      expect(message.attachments.single.size, 1024);
    });
  });

  group('UserProfile/Me avatar', () {
    test(
        'no avatar reads as null, and an older server omitting the key '
        'reads the same way', () {
      final profile = UserProfile.fromJson({
        'id': 'u',
        'username': 'bob',
        'display_name': 'Bob',
        'created_at': 1,
      });
      expect(profile.avatarUpdatedAt, isNull);
    });

    test('a set avatar carries when it was last updated', () {
      final profile = UserProfile.fromJson({
        'id': 'u',
        'username': 'bob',
        'display_name': 'Bob',
        'created_at': 1,
        'avatar_updated_at': 555,
      });
      expect(profile.avatarUpdatedAt, 555);

      final me = Me.fromJson({
        'id': 'u',
        'username': 'bob',
        'display_name': 'Bob',
        'created_at': 1,
        'permissions': 0,
        'avatar_updated_at': 555,
      });
      expect(me.avatarUpdatedAt, 555);
    });
  });

  group('Me timeout and status fields', () {
    // These back the timed-out banner (MOD6) and the status line.
    test('a timed-out account carries its deadline, reason and status', () {
      final me = Me.fromJson({
        'id': 'u',
        'username': 'bob',
        'display_name': 'Bob',
        'created_at': 1,
        'permissions': 0,
        'timed_out_until': 1712345678,
        'timeout_reason': 'spamming',
        'status_text': 'brb',
      });
      expect(me.timedOutUntil, 1712345678);
      expect(me.timeoutReason, 'spamming');
      expect(me.statusText, 'brb');
    });

    test('an account with none set, or an older server, reads them null', () {
      final me = Me.fromJson({
        'id': 'u',
        'username': 'bob',
        'display_name': 'Bob',
        'created_at': 1,
        'permissions': 0,
      });
      expect(me.timedOutUntil, isNull);
      expect(me.timeoutReason, isNull);
      expect(me.statusText, isNull);
    });
  });

  group('presence', () {
    test('listPresence sends a comma-joined id batch and parses statuses',
        () async {
      Uri? seen;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode([
              {'user_id': 'a', 'status': 'online'},
              {'user_id': 'b', 'status': 'offline'},
            ]),
            200,
          );
        }),
      );
      final result = await api.listPresence(['a', 'b']);
      expect(seen!.queryParameters['ids'], 'a,b');
      expect(result, hasLength(2));
      expect(result.first.status, PresenceState.online);
      expect(result.last.status, PresenceState.offline);
    });

    test('setPresenceVisibility round-trips the wire enum name', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'visibility': 'hidden'}), 200);
        }),
      );
      final result = await api.setPresenceVisibility(PresenceVisibility.hidden);
      expect(sentBody!['visibility'], 'hidden');
      expect(result, PresenceVisibility.hidden);
    });
  });

  group('direct messages', () {
    test('listDirectMessages parses each conversation', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response(
              jsonEncode([
                {
                  'channel_id': 'c1',
                  'user': {
                    'id': 'u2',
                    'username': 'ann',
                    'display_name': 'Ann',
                    'created_at': 1,
                  },
                  'unread': 3,
                  'created_at': 10,
                },
              ]),
              200,
            )),
      );
      final dms = await api.listDirectMessages();
      expect(dms, hasLength(1));
      expect(dms.single.user.username, 'ann');
      expect(dms.single.unread, 3);
    });

    test('openDirectMessage posts to the target user with no body', () async {
      String? path;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          path = '${request.method} ${request.url.path}';
          return http.Response(
            jsonEncode({
              'channel_id': 'c1',
              'user': {
                'id': 'u2',
                'username': 'ann',
                'display_name': 'Ann',
                'created_at': 1,
              },
              'unread': 0,
              'created_at': 10,
            }),
            200,
          );
        }),
      );
      final dm = await api.openDirectMessage('u2');
      expect(path, 'POST /dms/u2');
      expect(dm.channelId, 'c1');
    });
  });

  group('pins and polls', () {
    test('pin and unpin hit the right method and path', () async {
      final calls = <String>[];
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return http.Response('', 204);
        }),
      );
      await api.pinMessage(channelId: 'c', messageId: 'm');
      await api.unpinMessage(channelId: 'c', messageId: 'm');
      expect(calls, [
        'PUT /channels/c/messages/m/pin',
        'DELETE /channels/c/messages/m/pin',
      ]);
    });

    test('listPinnedMessages parses the flattened message plus pin metadata',
        () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response(
              jsonEncode([
                {
                  ..._messageJson(),
                  'pinned_at': 42,
                  'pinned_by': 'u',
                },
              ]),
              200,
            )),
      );
      final pins = await api.listPinnedMessages('c');
      expect(pins.single.message.id, 'm');
      expect(pins.single.pinnedAt, 42);
      expect(pins.single.pinnedBy, 'u');
    });

    test('sendPollMessage sends options in order and parses the poll back',
        () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(_messageJson(poll: {
              'question': 'lunch?',
              'options': [
                {'position': 0, 'label': 'pizza', 'votes': 0},
                {'position': 1, 'label': 'salad', 'votes': 0},
              ],
              'total_votes': 0,
              'voted_option': null,
              'close_at': null,
              'closed': false,
            })),
            200,
          );
        }),
      );
      final message = await api.sendPollMessage(
        channelId: 'c',
        id: 'm',
        question: 'lunch?',
        options: ['pizza', 'salad'],
      );
      expect(sentBody!['options'], ['pizza', 'salad']);
      expect(sentBody!.containsKey('content'), isFalse);
      expect(message.poll!.options.map((o) => o.label), ['pizza', 'salad']);
    });

    test('votePoll sends the chosen position', () async {
      Map<String, dynamic>? sentBody;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      await api.votePoll(messageId: 'm', option: 1);
      expect(sentBody!['option'], 1);
    });
  });

  group('attachments and avatars', () {
    test(
        'uploadAttachment sends raw bytes and the filename as a query '
        'parameter', () async {
      List<int>? sentBytes;
      String? sentContentType;
      Uri? sentUri;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          sentBytes = request.bodyBytes;
          sentContentType = request.headers['content-type'];
          sentUri = request.url;
          return http.Response(
            jsonEncode({
              'id': 'deadbeef',
              'filename': 'photo.png',
              'content_type': 'image/png',
              'size': 3,
            }),
            201,
          );
        }),
      );
      final attachment =
          await api.uploadAttachment([1, 2, 3], filename: 'photo.png');
      expect(sentBytes, [1, 2, 3]);
      expect(sentContentType, 'application/octet-stream');
      expect(sentUri!.queryParameters['filename'], 'photo.png');
      expect(attachment.id, 'deadbeef');
      expect(attachment.size, 3);
    });

    test('fetchAttachment returns raw bytes and the declared content type',
        () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response.bytes(
              [4, 5, 6],
              200,
              headers: {'content-type': 'image/png'},
            )),
      );
      final fetched = await api.fetchAttachment('deadbeef');
      expect(fetched.bytes, [4, 5, 6]);
      expect(fetched.contentType, 'image/png');
    });

    test('fetchAttachment refreshes once on an expired token and replays',
        () async {
      final calls = <String>[];
      var served = 0;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/auth/refresh') {
            return http.Response(
              jsonEncode({
                'user_id': 'user-1',
                'access_token': 'access-2',
                'refresh_token': 'refresh-2',
                'access_expires_at': 99,
              }),
              200,
            );
          }
          served++;
          if (served == 1) return http.Response('{"error":"expired"}', 401);
          return http.Response.bytes([1], 200,
              headers: {'content-type': 'application/octet-stream'});
        }),
      );
      final fetched = await api.fetchAttachment('deadbeef');
      expect(fetched.bytes, [1]);
      expect(calls, [
        'GET /attachments/deadbeef',
        'POST /auth/refresh',
        'GET /attachments/deadbeef',
      ]);
    });

    test('deleteAvatar expects no content', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
      await api.deleteAvatar();
    });

    test('fetchAvatar returns raw bytes', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((_) async => http.Response.bytes(
              [9, 9],
              200,
              headers: {'content-type': 'image/webp'},
            )),
      );
      final fetched = await api.fetchAvatar('u2');
      expect(fetched.bytes, [9, 9]);
      expect(fetched.contentType, 'image/webp');
    });
  });
}
