// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Integration test against a real running slim-m server.
///
/// Skipped unless `SLIMM_TEST_SERVER` is set, so CI and everyday `dart test`
/// stay hermetic:
///
/// ```
/// SLIMM_TEST_SERVER=http://10.0.0.100:8095 dart test test/live_server_test.dart
/// ```
///
/// This is the test that proves the client and server actually agree. The unit
/// tests assert what this client believes; only this one checks that belief
/// against the thing it will really talk to.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

/// A real v7: 48-bit big-endian millisecond prefix, version and variant bits
/// set, the rest random. Time-ordered, which is what the server's storage
/// locality assumes.
String _uuidV7() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final random = List<int>.generate(10, (_) => _rand.nextInt(256));
  final bytes = <int>[
    (now >> 40) & 0xff,
    (now >> 32) & 0xff,
    (now >> 24) & 0xff,
    (now >> 16) & 0xff,
    (now >> 8) & 0xff,
    now & 0xff,
    ...random,
  ];
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final _rand = Random();

void main() {
  final serverUrl = Platform.environment['SLIMM_TEST_SERVER'];
  if (serverUrl == null || serverUrl.isEmpty) {
    // Nothing to talk to; the suite is a no-op rather than a failure.
    return;
  }
  final base = Uri.parse(serverUrl);
  final suffix = DateTime.now().microsecondsSinceEpoch.toString();

  late SlimmApi api;
  late TokenPair shared;

  // One account for all tests: the password rate limit is a burst of five
  // refilling slowly, and sharing is closer to a real client anyway.
  setUpAll(() async {
    final bootstrap = SlimmApi(baseUrl: base);
    shared = await bootstrap.register(
      username: 'dart$suffix',
      displayName: 'Dart Client',
      password: 'hunter2hunter2',
      deviceName: 'integration',
    );
    bootstrap.close();
  });

  setUp(() =>
      api = SlimmApi(baseUrl: base, session: SessionStore(tokens: shared)));
  tearDown(() => api.close());

  test('the server is reachable and speaks our protocol', () async {
    expect((await http.get(base.replace(path: '/healthz'))).statusCode, 200);
    final version = await api.version();
    expect(version.name, 'slim-m');
    expect(
      version.protocol,
      protocolVersion,
      reason: 'this client only understands protocol $protocolVersion',
    );
  });

  test('register, send, read back, and edit', () async {
    expect(api.session.isSignedIn, isTrue);

    final channels = await api.listChannels();
    expect(channels, isNotEmpty, reason: 'bootstrap seeds a general channel');
    final channel = channels.first;

    final id = _uuidV7();
    final sent = await api.sendMessage(
      channelId: channel.id,
      id: id,
      content: 'hello from the dart client',
    );
    expect(sent.id, id);
    expect(sent.seq, greaterThan(0));

    // The same id must not send twice, however many times it is retried.
    final retried = await api.sendMessage(
      channelId: channel.id,
      id: id,
      content: 'this content is ignored',
    );
    expect(retried.seq, sent.seq);
    expect(retried.content, sent.content);

    final history = await api.listMessages(channel.id, limit: 10);
    expect(history.where((m) => m.id == id), hasLength(1));

    final edited = await api.editMessage(
      channelId: channel.id,
      messageId: id,
      content: 'edited from the dart client',
    );
    expect(edited.content, 'edited from the dart client');
    expect(edited.editedAt, isNotNull);
  });

  test('read state and catch-up sync agree with what was sent', () async {
    final channel = (await api.listChannels()).first;

    await api.sendMessage(
      channelId: channel.id,
      id: _uuidV7(),
      content: 'sync probe',
    );

    final before = await api.readState(channel.id);
    expect(before.unread, greaterThan(0));

    final after = await api.markRead(
        channelId: channel.id, seq: before.unread + before.lastReadSeq);
    expect(after.lastReadSeq, greaterThanOrEqualTo(before.lastReadSeq));

    final deltas =
        await api.sync([ScopeCursor(channelId: channel.id, afterSeq: 0)]);
    expect(deltas, hasLength(1));
    expect(deltas.single.messages, isNotEmpty);
    // Catch-up is oldest first, the opposite of history.
    final seqs = deltas.single.messages.map((m) => m.seq).toList();
    expect(seqs, orderedEquals(List.of(seqs)..sort()));
  });

  test('the websocket delivers a message sent over rest', () async {
    final channel = (await api.listChannels()).first;

    final ticket = await api.webSocketTicket();
    final connection = await EventConnection.connect(
      url: api.webSocketUrl,
      ticket: ticket.ticket,
    );
    addTearDown(connection.close);

    final delivered = connection.events
        .where((e) => e is MessageCreated)
        .cast<MessageCreated>()
        .first
        .timeout(const Duration(seconds: 10));

    final id = _uuidV7();
    await api.sendMessage(
      channelId: channel.id,
      id: id,
      content: 'over the socket',
    );

    final event = await delivered;
    expect(event.message.id, id);
    expect(event.message.content, 'over the socket');
  });

  test('a spent ticket cannot be redeemed twice', () async {
    final ticket = await api.webSocketTicket();
    final first = await EventConnection.connect(
      url: api.webSocketUrl,
      ticket: ticket.ticket,
    );
    addTearDown(first.close);

    await expectLater(
      EventConnection.connect(url: api.webSocketUrl, ticket: ticket.ticket),
      throwsA(isA<EventConnectionRefused>()),
    );
  });

  test('permissions are refused the same way as a missing channel', () async {
    // An ordinary member cannot create channels.
    await expectLater(
      api.createChannel(name: 'not-allowed'),
      throwsA(isA<ForbiddenException>()),
    );
    // A channel that does not exist is refused identically, so its absence is
    // not observable.
    await expectLater(
      api.listMessages(_uuidV7()),
      throwsA(isA<ForbiddenException>()),
    );
  });

  test('deleting the account revokes the session immediately', () async {
    // Needs a throwaway account of its own, so it registers with backoff rather
    // than reusing the shared one.
    final throwaway = SlimmApi(baseUrl: base);
    addTearDown(throwaway.close);
    await _registerWithBackoff(
      throwaway,
      username: 'del$suffix',
      displayName: 'Delete Client',
    );
    api = throwaway;
    await api.deleteAccount(password: 'hunter2hunter2');
    expect(api.session.isSignedIn, isFalse);

    await expectLater(
      api.login(
        username: 'del$suffix',
        password: 'hunter2hunter2',
        deviceName: 'integration',
      ),
      throwsA(isA<UnauthorizedException>()),
    );
  });
}

/// Registers, waiting out the password rate-limit class if it is exhausted.
/// Real clients should back off on a 429 the same way.
Future<void> _registerWithBackoff(
  SlimmApi api, {
  required String username,
  required String displayName,
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      await api.register(
        username: username,
        displayName: displayName,
        password: 'hunter2hunter2',
        deviceName: 'integration',
      );
      return;
    } on RateLimitedException {
      if (attempt >= 3) rethrow;
      await Future<void>.delayed(Duration(seconds: 7 * (attempt + 1)));
    }
  }
}
