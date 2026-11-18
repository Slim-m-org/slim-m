// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which Cloudflare data centre the API passes through, read from its own traffic.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
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

SlimmApi _api(Map<String, String> headers, {String body = '{}'}) => SlimmApi(
      baseUrl: Uri.parse('https://slim.example.org'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
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
