// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native shortcut against real TLS servers on loopback: it takes an
/// advertised address only when that address proves to be the server, and
/// otherwise falls back to the public route and stops trying for a while.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:slimm_api/src/direct_route_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/status.dart' as status;

const _fixtures = 'test/fixtures/direct_route';
const _host = 'slimm.test';

/// The port the app was pointed at; a direct address is only taken on this one.
const _port = 8443;

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

  /// Where a dial to the advertised address really lands: a test server's
  /// ephemeral port, since the advertised one must be the server's own port.
  late int directTarget;

  setUp(() async {
    (public, publicSeen) = await _server('public', _host);
    now = DateTime(2026);
    directTarget = 1;
  });

  IoDirectRoute route() {
    final route = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, directTarget),
      clock: () => now,
    );
    addTearDown(route.httpClient.close);
    return route;
  }

  const lan = '127.0.0.1:$_port';

  Future<String> get(IoDirectRoute r, String path) async =>
      (await r.httpClient.get(Uri.parse('https://$_host:$_port$path'))).body;

  test('an advertised address that is the server carries the requests',
      () async {
    final (direct, directSeen) = await _server('direct', _host);
    directTarget = direct.port;
    final r = route()..advertise([lan]);

    expect(await get(r, '/version'), 'direct');
    expect(r.active, isTrue);
    expect(directSeen, ['/version']);
    expect(publicSeen, isEmpty);
  });

  test(
      'an address holding some other certificate is refused, the public '
      'route is used, and the address is left alone for a while', () async {
    final (impostor, impostorSeen) = await _server('impostor', 'other.test');
    directTarget = impostor.port;
    final r = route()..advertise([lan]);

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
    directTarget = port;
    final r = route()..advertise([lan]);
    // Not kept alive, or the next request would reuse this public connection.
    final first = await r.httpClient.send(
      http.Request('GET', Uri.parse('https://$_host:$_port/a'))
        ..persistentConnection = false,
    );
    expect(await first.stream.bytesToString(), 'public');

    final (direct, _) = await _server('direct', _host);
    directTarget = direct.port;
    r.advertise(['127.0.0.1:$_port', '10.0.0.5:$_port']);
    expect(await get(r, '/b'), 'direct', reason: 'new addresses reset it');
  });

  test('a switch between the routes is announced once each way', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final (direct, _) = await _server('direct', _host);
    final r = route();
    final seen = <bool>[];
    r.activeChanges.listen(seen.add);

    directTarget = direct.port;
    r.advertise([lan]);
    await get(r, '/a');
    await get(r, '/b');
    directTarget = port;
    r.advertise(['10.0.0.5:$_port']);
    await get(r, '/c');
    await pumpEventQueue();

    expect(seen, [true, false]);
  });

  test('the event socket takes the same route', () async {
    final (direct, _) = await _server('direct', _host);
    directTarget = direct.port;
    final r = route()..advertise([lan]);
    final channel = r.connectWebSocket(
      Uri.parse('wss://$_host:$_port/ws'),
    );
    expect(await channel.stream.first, 'direct');
    await channel.sink.close(status.normalClosure);
  });

  test('another host is never shortcut', () async {
    final (direct, directSeen) = await _server('direct', _host);
    directTarget = direct.port;
    final r = route()..advertise([lan]);
    // The public server's certificate names slimm.test, so reaching it as elsewhere.test must fail.
    await expectLater(
      r.httpClient.get(Uri.parse('https://elsewhere.test:$_port/')),
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

    directTarget = direct.port;
    r.advertise([lan]);
    expect(await get(r, '/upload'), 'direct');
    expect(directSeen, ['/upload']);
  });

  test(
      'once the back-off ends the next request tries the address again, '
      'even with a public connection kept alive', () async {
    final (direct, _) = await _server('direct', _host);
    var reachable = false;
    final r = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) => reachable
          ? Socket.connect(InternetAddress.loopbackIPv4, direct.port)
          : Future.error(const SocketException('unreachable')),
      clock: () => now,
    );
    addTearDown(r.httpClient.close);
    r.advertise(['10.0.0.100:$_port']);

    expect(await get(r, '/a'), 'public');
    reachable = true;
    expect(await get(r, '/b'), 'public', reason: 'still backing off');

    now = now.add(const Duration(minutes: 2));
    expect(await get(r, '/c'), 'direct');
    expect(r.active, isTrue);
  });

  test('an address a hostile server picked is never dialled', () async {
    final dialled = <String>[];
    final r = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) {
        dialled.add('$host:$port');
        return Future.error(const SocketException('unreachable'));
      },
      clock: () => now,
    );
    addTearDown(r.httpClient.close);
    r.advertise(['127.0.0.1:22', '8.8.8.8:$_port', 'router.lan:$_port']);

    expect(await get(r, '/a'), 'public');
    expect(dialled, isEmpty);
  });

  test('retryNow ends a back-off at once, so a large upload goes direct',
      () async {
    final (direct, _) = await _server('direct', _host);
    var reachable = false;
    final r = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) => reachable
          ? Socket.connect(InternetAddress.loopbackIPv4, direct.port)
          : Future.error(const SocketException('unreachable')),
      clock: () => now,
    );
    addTearDown(r.httpClient.close);
    r.advertise(['10.0.0.100:$_port']);
    expect(await get(r, '/a'), 'public');
    reachable = true;
    expect(await get(r, '/b'), 'public', reason: 'still backing off');

    r.retryNow();
    expect(await get(r, '/c'), 'direct');
    expect(r.active, isTrue);
  });

  group('an address that never answers', () {
    late List<String> dials;
    late IoDirectRoute r;

    setUp(() {
      dials = [];
      r = IoDirectRoute(
        Uri.parse('https://$_host:$_port'),
        context: _trusting,
        connectPublic: (host, port) =>
            Socket.connect(InternetAddress.loopbackIPv4, public.port),
        connectDirect: (host, port) {
          dials.add(host);
          return Completer<Socket>().future;
        },
        clock: () => now,
      );
      addTearDown(r.httpClient.close);
      r.advertise(['10.0.0.100:$_port']);
    });

    test('times out, goes public, and is not dialled by the next request',
        () async {
      final watch = Stopwatch()..start();
      expect(await get(r, '/a'), 'public');
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(dials, hasLength(1));
      expect(r.active, isFalse);

      expect(await get(r, '/b'), 'public');
      expect(dials, hasLength(1), reason: 'the route is marked down');
    });

    test('is probed again once the back-off has passed', () async {
      await get(r, '/a');
      now = now.add(const Duration(seconds: 30));
      await get(r, '/b');
      expect(dials, hasLength(1));

      now = now.add(const Duration(minutes: 2));
      await get(r, '/c');
      expect(dials, hasLength(2));
    });
  });

  test('invalidate drops a pooled LAN connection so the next request redials',
      () async {
    final (direct, _) = await _server('direct', _host);
    var dials = 0;
    final r = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) {
        dials++;
        return Socket.connect(InternetAddress.loopbackIPv4, direct.port);
      },
      clock: () => now,
    );
    addTearDown(r.httpClient.close);
    r.advertise(['10.0.0.100:$_port']);
    await get(r, '/a');
    await get(r, '/b');
    expect(dials, 1, reason: 'the second request reuses the pooled socket');

    r.invalidate();
    expect(r.active, isFalse);
    await get(r, '/c');
    expect(dials, 2);
    expect(r.active, isTrue);
  });

  group('pinned clients for the connection test', () {
    test('the direct client reaches the advertised address and no other',
        () async {
      final (direct, directSeen) = await _server('direct', _host);
      directTarget = direct.port;
      final r = route()..advertise([lan]);
      final pinned = r.pinnedClient(direct: true)!;
      addTearDown(pinned.close);

      final body =
          (await pinned.get(Uri.parse('https://$_host:$_port/x'))).body;
      expect(body, 'direct');
      expect(publicSeen, isEmpty);
    });

    test('the direct client does not fall back when the address is wrong',
        () async {
      final (impostor, _) = await _server('impostor', 'other.test');
      directTarget = impostor.port;
      final r = route()..advertise([lan]);
      final pinned = r.pinnedClient(direct: true)!;
      addTearDown(pinned.close);

      await expectLater(
        pinned.get(Uri.parse('https://$_host:$_port/x')),
        throwsA(anything),
      );
      expect(publicSeen, isEmpty);
    });

    test('the public client stays public while an address is advertised',
        () async {
      final (direct, directSeen) = await _server('direct', _host);
      directTarget = direct.port;
      final r = route()..advertise([lan]);
      final pinned = r.pinnedClient(direct: false)!;
      addTearDown(pinned.close);

      final body =
          (await pinned.get(Uri.parse('https://$_host:$_port/x'))).body;
      expect(body, 'public');
      expect(directSeen, isEmpty);
    });

    test('there is no direct client without an advertised address', () {
      final r = route();
      expect(r.hasAddresses, isFalse);
      expect(r.pinnedClient(direct: true), isNull);
      r.advertise([lan]);
      expect(r.hasAddresses, isTrue);
    });
  });
}
