// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A proxy the platform picks (https_proxy and friends) is honoured: the
/// connection factory used to dial the origin and ignore it, so the CONNECT the
/// client then wrote went into the origin's TLS stream.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:slimm_api/src/direct_route_io.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/direct_route';
const _host = 'slimm.test';
const _port = 8443;

final _trusting = SecurityContext()
  ..setTrustedCertificates('$_fixtures/ca.pem');

/// A forward proxy on loopback that records each request line it is sent.
///
/// A CONNECT is answered with 200 and tunnelled to [upstream]; any other
/// request is answered with "proxied" directly.
class _Proxy {
  _Proxy(this._server, this.upstream) {
    _server.listen(_serve);
  }

  static Future<_Proxy> start({int? upstream}) async => _Proxy(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        upstream,
      );

  final ServerSocket _server;
  final int? upstream;
  final requestLines = <String>[];

  int get port => _server.port;
  String get setting => 'PROXY 127.0.0.1:$port';

  Future<void> close() => _server.close();

  void _serve(Socket client) {
    final head = <int>[];
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      head.addAll(chunk);
      final text = latin1.decode(head);
      if (!text.contains('\r\n\r\n')) return;
      requestLines.add(text.split('\r\n').first);
      if (text.startsWith('CONNECT') && upstream != null) {
        final onward = await Socket.connect(
          InternetAddress.loopbackIPv4,
          upstream!,
        );
        client.write('HTTP/1.1 200 Connection established\r\n\r\n');
        sub.onData(onward.add);
        onward.listen(client.add, onDone: client.destroy);
        return;
      }
      await sub.cancel();
      client.write(
        'HTTP/1.1 200 OK\r\ncontent-length: 7\r\nconnection: close\r\n\r\n'
        'proxied',
      );
      await client.close();
    });
  }
}

Future<HttpServer> _tlsServer() async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    SecurityContext()
      ..useCertificateChain('$_fixtures/$_host.pem')
      ..usePrivateKey('$_fixtures/$_host.key'),
  );
  server.listen((request) async {
    request.response.write('origin');
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  test('a plain request goes to the proxy, not the origin', () async {
    final proxy = await _Proxy.start();
    addTearDown(proxy.close);
    final route = IoDirectRoute(
      Uri.parse('http://$_host'),
      findProxy: (_) => proxy.setting,
    );
    addTearDown(route.httpClient.close);

    final response = await route.httpClient.get(
      Uri.parse('http://$_host/ping'),
    );

    expect(response.body, 'proxied');
    expect(proxy.requestLines, ['GET http://$_host/ping HTTP/1.1']);
  });

  test('an https request tunnels through the proxy and reaches the origin',
      () async {
    final origin = await _tlsServer();
    final proxy = await _Proxy.start(upstream: origin.port);
    addTearDown(proxy.close);
    final route = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      findProxy: (_) => proxy.setting,
    );
    addTearDown(route.httpClient.close);

    final response = await route.httpClient.get(
      Uri.parse('https://$_host:$_port/ping'),
    );

    expect(response.body, 'origin');
    expect(proxy.requestLines, ['CONNECT $_host:$_port HTTP/1.1']);
  });

  test('a pinned client for the LAN address dials it, proxy or not', () async {
    final origin = await _tlsServer();
    final proxy = await _Proxy.start();
    addTearDown(proxy.close);
    final route = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      connectDirect: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, origin.port),
      findProxy: (_) => proxy.setting,
    )..advertise(['127.0.0.1:$_port']);
    addTearDown(route.httpClient.close);
    final lan = route.pinnedClient(direct: true)!;
    addTearDown(lan.close);

    final response = await lan.get(Uri.parse('https://$_host:$_port/ping'));

    expect(response.body, 'origin');
    expect(proxy.requestLines, isEmpty);
  });

  test('a pinned client for the public route goes through the proxy', () async {
    final origin = await _tlsServer();
    final proxy = await _Proxy.start(upstream: origin.port);
    addTearDown(proxy.close);
    final route = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: _trusting,
      findProxy: (_) => proxy.setting,
    );
    addTearDown(route.httpClient.close);
    final internet = route.pinnedClient(direct: false)!;
    addTearDown(internet.close);

    final response = await internet.get(
      Uri.parse('https://$_host:$_port/ping'),
    );

    expect(response.body, 'origin');
    expect(proxy.requestLines, ['CONNECT $_host:$_port HTTP/1.1']);
  });
}
