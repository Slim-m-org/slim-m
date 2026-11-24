// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A client for a server nobody vouched for yet reads a bounded reply and
/// never follows a redirect to another host.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/bounded_reply.dart';
import 'package:slimm_api/src/client_transport.dart';
import 'package:test/test.dart';

/// A JSON array padded with whitespace to about [bytes].
http.StreamedResponse _streamed(int bytes, {bool declare = false}) =>
    http.StreamedResponse(
      Stream.fromIterable([
        utf8.encode('['),
        for (var sent = 2; sent < bytes; sent += 4096)
          List<int>.filled(4096, 0x20),
        utf8.encode(']'),
      ]),
      200,
      contentLength: declare ? bytes : null,
      headers: {'content-type': 'application/json'},
    );

void main() {
  final base = Uri.parse('https://unvouched.example');

  test('a /version reply past the cap is refused as not a slim-m server',
      () async {
    final client = SlimmApi(
      baseUrl: base,
      unvouched: true,
      httpClient: MockClient.streaming(
        (request, _) async => _streamed(unvouchedReplyBytes * 4),
      ),
    );
    await expectLater(
        client.version(), throwsA(isA<NotASlimServerException>()));
  });

  test('a reply that declares more than the cap is refused before reading',
      () async {
    final client = SlimmApi(
      baseUrl: base,
      unvouched: true,
      httpClient: MockClient.streaming(
        (request, _) async => _streamed(unvouchedReplyBytes + 1, declare: true),
      ),
    );
    await expectLater(
      client.send('GET', '/version', authenticated: false),
      throwsA(isA<UnreadableReplyException>()),
    );
  });

  test('a vouched client still reads a large reply whole', () async {
    final client = SlimmApi(
      baseUrl: base,
      httpClient: MockClient.streaming(
        (request, _) async => _streamed(unvouchedReplyBytes * 2),
      ),
    );
    expect(await client.send('GET', '/x', authenticated: false), isEmpty);
  });

  test('image bytes are refused past the cap the caller names', () async {
    final client = SlimmApi(
      baseUrl: base,
      unvouched: true,
      httpClient: MockClient.streaming(
        (request, _) async => _streamed(64 * 1024),
      ),
    );
    await expectLater(
      client.fetchPublicBytes('/invites/abc/icon', maxBytes: 16 * 1024),
      throwsA(isA<UnreadableReplyException>()),
    );
    expect(
      await client.fetchPublicBytes('/invites/abc/icon', maxBytes: 128 * 1024),
      hasLength(greaterThan(64 * 1024)),
    );
  });

  group('redirects', () {
    late HttpServer target;
    late HttpServer redirecting;
    late List<String> reached;

    setUp(() async {
      reached = [];
      target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) {
        reached.add(request.uri.path);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'name': 'slim-m', 'version': '1', 'protocol': 1}))
          ..close();
      });
      redirecting = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirecting.listen((request) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', 'http://localhost:${target.port}/version')
          ..close();
      });
      addTearDown(() => target.close(force: true));
      addTearDown(() => redirecting.close(force: true));
    });

    test('an unvouched client does not follow a redirect to another host',
        () async {
      final client = SlimmApi(
        baseUrl: Uri.parse('http://127.0.0.1:${redirecting.port}'),
        unvouched: true,
      );
      addTearDown(client.close);
      await expectLater(
          client.version(), throwsA(isA<NotASlimServerException>()));
      expect(reached, isEmpty);
    });

    test('a vouched client follows it as before', () async {
      final client = SlimmApi(
        baseUrl: Uri.parse('http://127.0.0.1:${redirecting.port}'),
      );
      addTearDown(client.close);
      await client.version();
      expect(reached, ['/version']);
    });
  });
}
