// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The LAN addresses come from the signed-in `GET /direct-route`, never from
/// the public `/version`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/direct_route.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _RecordingRoute implements DirectRoute {
  final advertised = <List<String>>[];

  @override
  void advertise(List<String> addresses) => advertised.add(addresses);

  @override
  bool get active => false;

  @override
  bool get hasAddresses => false;

  @override
  void retryNow() {}

  @override
  void invalidate() {}

  @override
  http.Client? pinnedClient({required bool direct}) => null;

  @override
  Stream<bool> get activeChanges => const Stream.empty();

  @override
  http.Client get httpClient => throw UnimplementedError();

  @override
  WebSocketChannel connectWebSocket(Uri url) => throw UnimplementedError();
}

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late _RecordingRoute route;
  late List<http.Request> seen;
  late SlimmApi api;

  setUp(() {
    route = _RecordingRoute();
    seen = [];
    api = SlimmApi(
      baseUrl: Uri.parse('https://slimm.test'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      directRoute: route,
      httpClient: MockClient((request) async {
        seen.add(request);
        if (request.url.path == '/direct-route') {
          return _json({
            'addresses': ['10.0.0.100:443'],
          });
        }
        return _json({
          'name': 'slim-m',
          'version': '1.0.0',
          'protocol': 1,
          'direct_addresses': ['10.9.9.9:443'],
        });
      }),
    );
  });

  test('refreshDirectRoute asks as the signed-in member and advertises',
      () async {
    await api.refreshDirectRoute();

    expect(seen.single.url.path, '/direct-route');
    expect(seen.single.headers['authorization'], 'Bearer access');
    expect(route.advertised, [
      ['10.0.0.100:443'],
    ]);
  });

  test('the public /version no longer feeds the shortcut', () async {
    await api.version();

    expect(route.advertised, isEmpty);
  });
}
