// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RootFetchingHttpOverrides] against a real TLS server whose CA the default
/// context does not trust, as on a fresh Windows machine before Windows has
/// fetched that root. The connection is secured by hand with the default
/// context, the way the direct route does it for every api call.
///
/// The last test adds the CA to the default context, which lasts for the rest
/// of this file, so it runs last.
@TestOn('vm')
library;

import 'dart:io';

import 'package:slimm_api/src/root_fetching_http_client.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/direct_route';
final _url = Uri.parse('https://slimm.test/version');

Future<HttpServer> _server() async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    SecurityContext()
      ..useCertificateChain('$_fixtures/slimm.test.pem')
      ..usePrivateKey('$_fixtures/slimm.test.key'),
  );
  server.listen((request) async {
    request.response.write('ok');
    await request.response.close();
  });
  return server;
}

/// A client from `HttpClient()`, as every caller in the app builds one, that
/// dials [server] for slimm.test and secures it with the default context.
HttpClient _client(RootFetchingHttpOverrides overrides, HttpServer server) =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, overrides)
      ..connectionFactory =
          (url, proxyHost, proxyPort) async => ConnectionTask.fromSocket(
                Socket.connect(InternetAddress.loopbackIPv4, server.port).then(
                  (raw) => SecureSocket.secure(raw, host: url.host),
                ),
                () {},
              );

Future<String> _get(HttpClient client) async {
  final response = await (await client.getUrl(_url)).close();
  return response.transform(const SystemEncoding().decoder).join();
}

void main() {
  late HttpServer server;
  setUp(() async => server = await _server());
  tearDown(() => server.close(force: true));

  test('a client with its own context is the plain dart:io one', () {
    final overrides = RootFetchingHttpOverrides((_) async => true);
    expect(
      overrides.createHttpClient(SecurityContext()),
      isNot(isA<RootFetchingHttpClient>()),
    );
    expect(overrides.createHttpClient(null), isA<RootFetchingHttpClient>());
  });

  test('a handshake that fails for another reason fetches nothing', () async {
    final asked = <Uri>[];
    final overrides = RootFetchingHttpOverrides((url) async {
      asked.add(url);
      return true;
    });
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      overrides,
    )..connectionFactory = (url, proxyHost, proxyPort) async =>
        throw const HandshakeException(
            'Connection terminated during handshake');

    await expectLater(_get(client), throwsA(isA<HandshakeException>()));
    expect(asked, isEmpty);
  });

  test(
      'when no root can be added the failure stands, and the host is asked '
      'for once however many clients meet it', () async {
    final asked = <Uri>[];
    final overrides = RootFetchingHttpOverrides((url) async {
      asked.add(url);
      return false;
    });

    for (var i = 0; i < 2; i++) {
      await expectLater(
        _get(_client(overrides, server)),
        throwsA(
          predicate(RootFetchingHttpClient.isMissingRoot, 'a missing root'),
        ),
      );
    }
    expect(asked, [_url]);
  });

  test('a missing root is added and the same request opens again', () async {
    final asked = <Uri>[];
    final overrides = RootFetchingHttpOverrides((url) async {
      asked.add(url);
      SecurityContext.defaultContext.setTrustedCertificates(
        '$_fixtures/ca.pem',
      );
      return true;
    });
    final client = _client(overrides, server);

    expect(await _get(client), 'ok');
    expect(await _get(_client(overrides, server)), 'ok');
    expect(asked, [_url]);
  });
}
