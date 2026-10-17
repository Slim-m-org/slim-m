// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native shortcut against real TLS servers on loopback: it takes an
/// advertised address only when that address proves to be the server, and
/// otherwise falls back to the public route and stops trying for a while.
@TestOn('vm')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:slimm_api/src/direct_route_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/status.dart' as status;

const _fixtures = 'test/fixtures/direct_route';
const _host = 'slimm.test';

SecurityContext _serving(String name) => SecurityContext()
  ..useCertificateChain('$_fixtures/$name.pem')
  ..usePrivateKey('$_fixtures/$name.key');

final _trusting = SecurityContext()
  ..setTrustedCertificates('$_fixtures/ca.pem');

/// A TLS server answering every request with [label].
Future<(HttpServer, List<String>)> _server(String label, String cert) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    _serving(cert),
  );
  final seen = <String>[];
  server.listen((request) async {
    seen.add(request.uri.path);
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(label);
      await socket.close();
      return;
    }
    request.response.write(label);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return (server, seen);
}

void main() {
  late HttpServer public;
  late List<String> publicSeen;
  late DateTime now;

  setUp(() async {
    (public, publicSeen) = await _server('public', _host);
    now = DateTime(2026);
  });

  IoDirectRoute route() {
    final route = IoDirectRoute(
      Uri.parse('https://$_host:${public.port}'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, port),
      clock: () => now,
    );
    addTearDown(route.httpClient.close);
    return route;
  }

  Future<String> get(IoDirectRoute r, String path) async =>
      (await r.httpClient.get(Uri.parse('https://$_host:${public.port}$path')))
          .body;

  test('an advertised address that is the server carries the requests',
      () async {
    final (direct, directSeen) = await _server('direct', _host);
    final r = route()..advertise(['127.0.0.1:${direct.port}']);

    expect(await get(r, '/version'), 'direct');
    expect(r.active, isTrue);
    expect(directSeen, ['/version']);
    expect(publicSeen, isEmpty);
  });

  test(
      'an address holding some other certificate is refused, the public '
      'route is used, and the address is left alone for a while', () async {
    final (impostor, impostorSeen) = await _server('impostor', 'other.test');
    final r = route()..advertise(['127.0.0.1:${impostor.port}']);

    expect(await get(r, '/a'), 'public');
    expect(r.active, isFalse);
    expect(impostorSeen, isEmpty, reason: 'TLS failed before any request');

    r.httpClient.close();
  });

  test(
      'an unreachable address falls back, and is tried again after the '
      'back-off', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final r = route()..advertise(['127.0.0.1:$port']);
    // Not kept alive, or the next request would reuse this public connection.
    final first = await r.httpClient.send(
      http.Request('GET', Uri.parse('https://$_host:${public.port}/a'))
        ..persistentConnection = false,
    );
    expect(await first.stream.bytesToString(), 'public');

    final (direct, _) = await _server('direct', _host);
    r.advertise(['127.0.0.1:${direct.port}']);
    expect(await get(r, '/b'), 'direct', reason: 'new addresses reset it');
  });

  test('the event socket takes the same route', () async {
    final (direct, _) = await _server('direct', _host);
    final r = route()..advertise(['127.0.0.1:${direct.port}']);
    final channel = r.connectWebSocket(
      Uri.parse('wss://$_host:${public.port}/ws'),
    );
    expect(await channel.stream.first, 'direct');
    await channel.sink.close(status.normalClosure);
  });

  test('another host is never shortcut', () async {
    final (direct, directSeen) = await _server('direct', _host);
    final r = route()..advertise(['127.0.0.1:${direct.port}']);
    // The public server's certificate names slimm.test, so reaching it as elsewhere.test must fail.
    await expectLater(
      r.httpClient.get(Uri.parse('https://elsewhere.test:${public.port}/')),
      throwsA(isA<HandshakeException>()),
    );
    expect(directSeen, isEmpty);
  });

  test(
      'a connection opened before the address was known is not reused for '
      'the requests after it', () async {
    final (direct, directSeen) = await _server('direct', _host);
    final r = route();
    expect(await get(r, '/version'), 'public');

    r.advertise(['127.0.0.1:${direct.port}']);
    expect(await get(r, '/upload'), 'direct');
    expect(directSeen, ['/upload']);
  });

  test(
      'once the back-off ends the next request tries the address again, '
      'even with a public connection kept alive', () async {
    final (direct, _) = await _server('direct', _host);
    var reachable = false;
    final r = IoDirectRoute(
      Uri.parse('https://$_host:${public.port}'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, port),
      connectDirect: (host, port) => reachable
          ? Socket.connect(InternetAddress.loopbackIPv4, direct.port)
          : Future.error(const SocketException('unreachable')),
      clock: () => now,
    );
    addTearDown(r.httpClient.close);
    r.advertise(['10.0.0.100:443']);

    expect(await get(r, '/a'), 'public');
    reachable = true;
    expect(await get(r, '/b'), 'public', reason: 'still backing off');

    now = now.add(const Duration(minutes: 2));
    expect(await get(r, '/c'), 'direct');
    expect(r.active, isTrue);
  });
}
