// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's round trip over the native route, against a real TLS server
/// on loopback, while an advertised LAN address never answers.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/direct_route_io.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/direct_route';
const _host = 'slimm.test';
const _port = 8443;

Future<HttpServer> _server() async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    SecurityContext()
      ..useCertificateChain('$_fixtures/$_host.pem')
      ..usePrivateKey('$_fixtures/$_host.key'),
  );
  server.listen((request) async {
    request.response
      ..headers.contentType = ContentType.json
      ..headers.set('cf-ray', '8f1c2d3e4f5a6b7c-EWR')
      ..write('{}');
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

void main() {
  test('a LAN dial that fails is paid before the timing, never in it',
      () async {
    final server = await _server();
    var now = DateTime(2026, 11, 18, 20);
    final route = IoDirectRoute(
      Uri.parse('https://$_host:$_port'),
      context: SecurityContext()..setTrustedCertificates('$_fixtures/ca.pem'),
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, server.port),
      connectDirect: (host, port) => Completer<Socket>().future,
      clock: () => now,
    );
    final api = SlimmApi(
      baseUrl: Uri.parse('https://$_host:$_port'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      directRoute: route,
    );
    addTearDown(api.close);
    route.advertise(['10.0.0.100:$_port']);

    final first = await api.measureRoundTrip();
    expect(first!.colo, 'EWR');
    expect(first.direct, isFalse);
    expect(first.roundTrip, lessThan(const Duration(milliseconds: 350)));

    now = now.add(const Duration(minutes: 2));
    final again = await api.measureRoundTrip();
    expect(again!.roundTrip, lessThan(const Duration(milliseconds: 350)));
    expect(route.poolRenewals, 2,
        reason: 'the warm-up renewed it, not the timed ping');
  });
}
