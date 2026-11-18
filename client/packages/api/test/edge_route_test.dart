// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which Cloudflare data centre the API passes through, read from its own traffic.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_api/src/direct_route.dart';
import 'package:test/test.dart';

const _trace = '''fl=123f45
h=slim.example.org
ip=203.0.113.9
ts=1763496000.123
visit_scheme=https
uag=Mozilla/5.0
colo=GRU
sliver=none
http=http/2
loc=US
tls=TLSv1.3
warp=off
''';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

const _ray = {'cf-ray': '8f1c2d3e4f5a6b7c-EWR'};

http.Response _pong() => http.Response('{}', 200, headers: _ray);

SlimmApi _api(Map<String, String> headers, {String body = '{}'}) => SlimmApi(
      baseUrl: Uri.parse('https://slim.example.org'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient((request) async {
        if (request.url.path == '/cdn-cgi/trace') {
          return http.Response(body, 200);
        }
        final pingHeaders = request.url.path == '/diagnostics/ping'
            ? headers
            : const <String, String>{};
        return http.Response('{}', 200, headers: pingHeaders);
      }),
    );

/// An API whose pings, counted from zero, are answered by [ping].
SlimmApi _pinging(
  FutureOr<http.Response> Function(int n) ping, {
  DirectRoute? route,
}) {
  var n = 0;
  return SlimmApi(
    baseUrl: Uri.parse('https://slim.example.org'),
    session: SessionStore(tokens: _tokens),
    directRoute: route,
    httpClient: MockClient((request) async {
      if (request.url.path != '/diagnostics/ping') {
        return http.Response('{}', 200);
      }
      return ping(n++);
    }),
  );
}

/// A route whose pool a test renews by hand.
class _Route implements DirectRoute {
  @override
  int poolRenewals = 0;

  @override
  bool get active => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('cloudflareColoOf', () {
    test('reads the data centre a ray ends in', () {
      expect(cloudflareColoOf('a5c7609e888705ea-IAD'), 'IAD');
      expect(cloudflareColoOf('a5c7609e888705ea-gru'), 'GRU');
    });

    test('is null for anything else', () {
      expect(cloudflareColoOf(null), isNull);
      expect(cloudflareColoOf('a5c7609e888705ea'), isNull);
      expect(cloudflareColoOf('a5c7609e888705ea-PARIS'), isNull);
    });
  });

  group('parseCloudflareTrace', () {
    test('keeps the data centre and nothing else', () {
      final trace = parseCloudflareTrace(_trace)!;
      expect(trace, const EdgeTrace(colo: 'GRU'));
      expect(trace.toString(), isNot(contains('203.0.113.9')));
    });

    test('is null for a body that is not a trace', () {
      expect(parseCloudflareTrace('<html>Not found</html>'), isNull);
    });
  });

  group('the API edge', () {
    test('a timed request carries the data centre of that same response',
        () async {
      final api = _api({'cf-ray': '8f1c2d3e4f5a6b7c-GRU'});
      expect(api.edge.last, isNull);
      final at = DateTime(2026, 11, 18, 20);
      final reading = await api.measureRoundTrip(clock: () => at);
      expect(api.edge.last, same(reading));
      expect(reading!.colo, 'GRU');
      expect(reading.direct, isFalse);
      expect(reading.at, at);
    });

    test('a response with no ray says no Cloudflare was in between', () async {
      final api = _api(const {});
      final reading = await api.measureRoundTrip();
      expect(reading?.colo, isNull);
    });

    test(
        'the round trip is timed on a warm connection, not the one that '
        'opened it', () async {
      final api = _pinging((n) async {
        if (n == 0) await Future<void>.delayed(const Duration(seconds: 1));
        return _pong();
      });
      final reading = await api.measureRoundTrip();
      expect(reading!.roundTrip, lessThan(const Duration(milliseconds: 500)));
    });

    test('a timed ping that met a dropped socket is not kept', () async {
      final api = _pinging(
        (n) => n == 1 ? throw http.ClientException('reset by peer') : _pong(),
      );
      expect(await api.measureRoundTrip(), isNull);
      expect(api.edge.last, isNull);
    });

    test('a timed ping that needed a token refresh is not kept', () async {
      final api = _pinging((n) => n == 1 ? http.Response('', 401) : _pong());
      expect(await api.measureRoundTrip(), isNull);
      expect(api.edge.last, isNull);
    });

    test('a timed ping that went out on a fresh pool is not kept', () async {
      final route = _Route();
      final api = _pinging(
        (n) {
          if (n == 1) route.poolRenewals++;
          return _pong();
        },
        route: route,
      );
      expect(await api.measureRoundTrip(), isNull);
      expect(api.edge.last, isNull);
    });

    test('reads a trace from another host too', () async {
      final api = _api(const {}, body: _trace);
      final trace = await api.cloudflareTrace(
        host: Uri.parse('wss://livekit.example.org'),
      );
      expect(trace?.colo, 'GRU');
    });

    test('a trace that is not there is null, never a throw', () async {
      final api = SlimmApi(
        baseUrl: Uri.parse('https://slim.example.org'),
        httpClient: MockClient((_) async => http.Response('nope', 404)),
      );
      expect(await api.cloudflareTrace(), isNull);
    });
  });
}
