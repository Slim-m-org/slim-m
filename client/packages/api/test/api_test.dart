// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unit tests for parsing, error mapping, refresh behaviour, and event frames.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Uri get _base => Uri.parse('http://localhost:8080');

TokenPair _tokens({String access = 'access-1', String refresh = 'refresh-1'}) =>
    TokenPair(
      userId: 'user-1',
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: 0,
    );

void main() {
  group('models', () {
    test('a message keeps identity and order separate', () {
      final message = Message.fromJson({
        'id': '018f-uuid',
        'channel_id': 'chan-1',
        'author_id': 'user-1',
        'seq': 42,
        'content': 'hi',
        'created_at': 1000,
        'edited_at': null,
      });
      expect(message.id, '018f-uuid');
      expect(message.seq, 42);
      expect(message.editedAt, isNull);
    });

    test('a deleted author comes back as null, not a placeholder', () {
      final message = Message.fromJson({
        'id': 'm',
        'channel_id': 'c',
        'author_id': null,
        'seq': 1,
        'content': 'still here',
        'created_at': 1,
        'edited_at': 2,
      });
      expect(message.authorId, isNull);
      expect(message.editedAt, 2);
    });

    test('a server too old to report push reads as unknown, not false', () {
      final old = Version.fromJson({
        'name': 'slim-m',
        'version': '0.6.0',
        'protocol': 1,
      });
      expect(old.pushEnabled, isNull);

      final current = Version.fromJson({
        'name': 'slim-m',
        'version': '0.8.0',
        'protocol': 1,
        'push_enabled': false,
      });
      expect(current.pushEnabled, isFalse);
    });

    test('an unrecognised presence status reads as offline, not a throw', () {
      final status = PresenceStatus.fromJson({
        'user_id': 'user-1',
        'status': 'busy',
      });
      expect(status.status, PresenceState.offline);
    });

    test('an unrecognised report subject reads as user, not a throw', () {
      final report = Report.fromJson({
        'id': 'r1',
        'reporter_id': 'user-1',
        'subject_kind': 'canvas_object',
        'subject_id': 'obj-1',
        'channel_id': null,
        'reason': 'spam',
        'snapshot': null,
        'subject_author_id': null,
        'created_at': 1,
      });
      expect(report.subjectKind, ReportSubject.user);
    });

    test('a report carries its per-channel bitmask when the server sends one',
        () {
      final report = Report.fromJson({
        'id': 'r1',
        'reporter_id': 'user-1',
        'subject_kind': 'message',
        'subject_id': 'msg-1',
        'channel_id': 'chan-1',
        'reason': 'spam',
        'snapshot': 'hi',
        'subject_author_id': 'user-2',
        'created_at': 1,
        'channel_permissions': 8,
      });
      expect(report.channelPermissions, 8);
    });

    test('a report omitting channel_permissions reads as unknown, not zero',
        () {
      final report = Report.fromJson({
        'id': 'r1',
        'reporter_id': 'user-1',
        'subject_kind': 'message',
        'subject_id': 'msg-1',
        'channel_id': 'chan-1',
        'reason': 'spam',
        'snapshot': 'hi',
        'subject_author_id': 'user-2',
        'created_at': 1,
      });
      expect(report.channelPermissions, isNull);
    });

    test('a channel carries its bitmask when the server sends one', () {
      final channel = Channel.fromJson({
        'id': 'chan-1',
        'name': 'general',
        'kind': 'text',
        'created_at': 1,
        'permissions': 16,
      });
      expect(channel.permissions, 16);
    });

    test('a channel omitting permissions reads as unknown, not zero', () {
      final channel = Channel.fromJson({
        'id': 'chan-1',
        'name': 'general',
        'kind': 'text',
        'created_at': 1,
      });
      expect(channel.permissions, isNull);
    });

    test('a channel carries restricted when the server sends it', () {
      final channel = Channel.fromJson({
        'id': 'chan-1',
        'name': 'staff',
        'kind': 'text',
        'created_at': 1,
        'restricted': true,
      });
      expect(channel.restricted, true);
    });

    test('a channel omitting restricted reads as unknown, not false', () {
      final channel = Channel.fromJson({
        'id': 'chan-1',
        'name': 'general',
        'kind': 'text',
        'created_at': 1,
      });
      expect(channel.restricted, isNull);
    });

    test('token and ticket toString never leak the secret', () {
      expect(_tokens(access: 'super-secret').toString(),
          isNot(contains('super-secret')));
      const ticket = Ticket(ticket: 'secret-ticket', expiresAt: 5);
      expect(ticket.toString(), isNot(contains('secret-ticket')));
    });
  });

  group('error mapping', () {
    Future<void> expectMapped(int status, String body, Matcher matcher) async {
      final api = SlimmApi(
        baseUrl: _base,
        httpClient: MockClient((_) async => http.Response(body, status)),
      );
      await expectLater(api.version, throwsA(matcher));
    }

    test('a 403 carries the refused permission bits', () async {
      await expectMapped(
        403,
        '{"error":"x","missing_permissions":32}',
        isA<ForbiddenException>().having(
          (e) => e.missingPermissions,
          'missingPermissions',
          32,
        ),
      );
    });

    test('statuses become typed exceptions carrying the reason', () async {
      await expectMapped(400, '{"error":"bad"}', isA<BadRequestException>());
      await expectMapped(
          403,
          '{"error":"insufficient permissions"}',
          isA<ForbiddenException>()
              .having((e) => e.message, 'message', 'insufficient permissions'));
      await expectMapped(404, '{"error":"gone"}', isA<NotFoundException>());
      await expectMapped(409, '{"error":"dup"}', isA<ConflictException>());
      await expectMapped(
          429, '{"error":"slow down"}', isA<RateLimitedException>());
      await expectMapped(503, '{"error":"busy"}', isA<UnavailableException>());
      await expectMapped(500, 'not json', isA<ServerException>());
    });

    test('a dead connection is a transport failure, not a server error',
        () async {
      final api = SlimmApi(
        baseUrl: _base,
        httpClient: MockClient((_) async => throw const SocketishFailure()),
      );
      await expectLater(api.version, throwsA(isA<TransportException>()));
    });
  });

  group('register', () {
    Future<Map<String, dynamic>> bodySentBy(
      Future<void> Function(SlimmApi api) call,
    ) async {
      late Map<String, dynamic> sent;
      final api = SlimmApi(
        baseUrl: _base,
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'user_id': 'user-1',
              'access_token': 'a',
              'refresh_token': 'r',
              'access_expires_at': 0,
            }),
            200,
          );
        }),
      );
      await call(api);
      return sent;
    }

    test('an invite code travels with the signup, not a later redeem',
        () async {
      final sent = await bodySentBy((api) => api.register(
            username: 'bob',
            displayName: 'Bob',
            password: 'hunter2hunter2',
            deviceName: 'cli',
            inviteCode: 'abc123',
          ));
      expect(sent['invite_code'], 'abc123');
    });

    test('no code means no field at all, so an unclaimed server is unaffected',
        () async {
      final sent = await bodySentBy((api) => api.register(
            username: 'alice',
            displayName: 'Alice',
            password: 'hunter2hunter2',
            deviceName: 'cli',
          ));
      expect(sent.containsKey('invite_code'), isFalse);
    });
  });

  group('refresh', () {
    test('an expired call refreshes once and replays', () async {
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
          // First protected call is expired; the replay succeeds.
          served++;
          if (served == 1) return http.Response('{"error":"expired"}', 401);
          return http.Response('[]', 200);
        }),
      );

      final channels = await api.listChannels();
      expect(channels, isEmpty);
      expect(calls, [
        'GET /channels',
        'POST /auth/refresh',
        'GET /channels',
      ]);
      expect(api.session.tokens!.accessToken, 'access-2');
    });

    test('concurrent expiries share one rotation, never spending it twice',
        () async {
      var refreshes = 0;
      var protectedCalls = 0;
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/refresh') {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
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
          protectedCalls++;
          // Every call before the rotation lands is expired.
          if (refreshes == 0) return http.Response('{"error":"expired"}', 401);
          return http.Response('[]', 200);
        }),
      );

      await Future.wait([
        api.listChannels(),
        api.listChannels(),
        api.listChannels(),
      ]);
      // Spending the single-use refresh token more than once would look like a
      // leak to the server and revoke the whole session.
      expect(refreshes, 1);
      expect(protectedCalls, greaterThan(3));
    });

    test(
        'a rotation does not resolve until the new token is durable, so a '
        'caller relying on refresh() having finished can never see a rotated '
        'token that is still only in memory', () async {
      final persistGate = Completer<void>();
      var persisted = false;
      final session = SessionStore(
        tokens: _tokens(),
        onChange: (tokens) async {
          await persistGate.future;
          persisted = true;
        },
      );
      final api = SlimmApi(
        baseUrl: _base,
        session: session,
        httpClient: MockClient((request) async {
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
          return http.Response('[]', 200);
        }),
      );

      final rotation = api.refresh();
      var settledBeforeGate = false;
      unawaited(rotation.then((_) => settledBeforeGate = persisted));

      // Live in memory already (other in-flight calls must keep working), but refresh() still waits.
      await Future<void>.delayed(Duration.zero);
      expect(session.tokens!.accessToken, 'access-2');
      expect(persisted, isFalse);

      persistGate.complete();
      await rotation;

      expect(
        settledBeforeGate,
        isTrue,
        reason: 'refresh() must not resolve before its own write lands',
      );
    });

    test('a rejected refresh ends the session rather than looping', () async {
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(tokens: _tokens()),
        httpClient:
            MockClient((_) async => http.Response('{"error":"nope"}', 401)),
      );
      await expectLater(
          api.listChannels, throwsA(isA<UnauthorizedException>()));
      expect(api.session.isSignedIn, isFalse);
    });
  });

  group('SessionStore.onChange', () {
    test(
        'a failed onChange does not disable it for later calls, the same '
        'trap a cached rejected future is elsewhere in this codebase',
        () async {
      final seen = <TokenPair?>[];
      final session = SessionStore(
        tokens: _tokens(),
        onChange: (tokens) async {
          seen.add(tokens);
          if (seen.length == 1) throw StateError('disk unavailable');
        },
      );

      session.set(_tokens(access: 'access-2'));
      await session.settled;
      session.set(_tokens(access: 'access-3'));
      await session.settled;

      expect(
        seen.map((t) => t?.accessToken),
        ['access-2', 'access-3'],
        reason: 'the second call must still run its onChange, not inherit '
            'the first one\'s rejection',
      );
    });
  });

  group('event frames', () {
    test('known frames parse into typed events', () {
      expect(ServerEvent.parse('{"type":"hello","protocol":1}'),
          isA<HelloEvent>());
      expect(ServerEvent.parse('{"type":"pong"}'), isA<PongEvent>());
      final created = ServerEvent.parse(jsonEncode({
        'type': 'message.created',
        'channel_id': 'c',
        'seq': 7,
        'message': {
          'id': 'm',
          'channel_id': 'c',
          'author_id': 'u',
          'seq': 7,
          'content': 'hey',
          'created_at': 1,
          'edited_at': null,
        },
      }));
      expect(created, isA<MessageCreated>());
      expect((created! as MessageCreated).message.seq, 7);
    });

    test('a resync error is recognisable, so the caller can catch up', () {
      final event = ServerEvent.parse('{"type":"error","message":"resync"}');
      expect((event! as ErrorEvent).needsResync, isTrue);
    });

    test('unknown and malformed frames are ignored, not fatal', () {
      // The server must be able to add event types without breaking older
      // clients, so anything unrecognized is skipped.
      expect(ServerEvent.parse('{"type":"reaction.added"}'), isNull);
      expect(ServerEvent.parse('not json'), isNull);
      expect(ServerEvent.parse('[]'), isNull);
    });
  });

  test('the websocket url is derived from the base url scheme', () {
    expect(
      SlimmApi(baseUrl: Uri.parse('https://chat.example'))
          .webSocketUrl
          .toString(),
      'wss://chat.example/ws',
    );
    expect(
      SlimmApi(baseUrl: Uri.parse('http://localhost:8095'))
          .webSocketUrl
          .toString(),
      'ws://localhost:8095/ws',
    );
  });
}

/// Stands in for a dead socket without depending on dart:io in tests.
class SocketishFailure implements Exception {
  const SocketishFailure();
}
