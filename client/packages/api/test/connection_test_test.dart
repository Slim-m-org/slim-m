// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The connection test: its arithmetic against fake probes, and its real
/// probe against a loopback server that speaks the diagnostics routes.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

class _FakeProbe implements ConnectionProbe {
  _FakeProbe({
    this.pings = const [],
    this.bytesPerSecond = 12.5e6,
    this.failWith,
  });

  final List<int> pings;
  final double bytesPerSecond;
  final ApiException? failWith;
  final asked = <String>[];
  var closed = false;
  var _ping = 0;

  @override
  bool get viaCloudflare => false;

  @override
  Future<Duration> ping({UploadCancelToken? cancel}) async {
    if (failWith case final error?) throw error;
    return Duration(milliseconds: pings[_ping++ % pings.length]);
  }

  Future<ProbeTransfer> _move(String kind, int bytes) async {
    asked.add('$kind $bytes');
    return ProbeTransfer(
      bytes,
      Duration(microseconds: (bytes / bytesPerSecond * 1e6).round()),
    );
  }

  @override
  Future<ProbeTransfer> download(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) =>
      _move('down', bytes);

  @override
  Future<ProbeTransfer> upload(
    int bytes, {
    UploadCancelToken? cancel,
    void Function(int done)? onProgress,
  }) =>
      _move('up', bytes);

  @override
  void close() => closed = true;
}

void main() {
  group('runConnectionTest', () {
    test('takes the median latency, ignoring the warm-up ping', () async {
      final probe = _FakeProbe(pings: [900, 30, 10, 50, 20, 40]);
      final results =
          await runConnectionTest([(ConnectionRoute.internet, probe)]);
      expect(results.single.latency, const Duration(milliseconds: 30));
    });

    test('sizes the second transfer to last a few seconds, under the cap',
        () async {
      final probe = _FakeProbe(pings: [1], bytesPerSecond: 4194304);
      final results = await runConnectionTest([(ConnectionRoute.lan, probe)]);
      expect(probe.asked, [
        'down 1048576',
        'down ${12582912}',
        'up 1048576',
        'up ${12582912}',
      ]);
      expect(results.single.downloadBps, closeTo(4194304 * 8, 1));
      expect(results.single.uploadBps, closeTo(4194304 * 8, 1));

      final fast = _FakeProbe(pings: [1], bytesPerSecond: 500e6);
      await runConnectionTest([(ConnectionRoute.lan, fast)]);
      expect(fast.asked[1], 'down ${24 * 1024 * 1024}');
    });

    test('a link too slow for a bigger transfer reports the small one',
        () async {
      final probe = _FakeProbe(pings: [1], bytesPerSecond: 100e3);
      final results =
          await runConnectionTest([(ConnectionRoute.internet, probe)]);
      expect(probe.asked, ['down 1048576', 'up 1048576']);
      expect(results.single.downloadBps, closeTo(800e3, 1));
    });

    test('measures every route in turn and closes each probe', () async {
      final lan = _FakeProbe(pings: [2], bytesPerSecond: 60e6);
      final net = _FakeProbe(pings: [30], bytesPerSecond: 10e6);
      final results = await runConnectionTest([
        (ConnectionRoute.lan, lan),
        (ConnectionRoute.internet, net),
      ]);
      expect(results.map((r) => r.route),
          [ConnectionRoute.lan, ConnectionRoute.internet]);
      expect(results[0].downloadBps! > results[1].downloadBps!, isTrue);
      expect(lan.closed && net.closed, isTrue);
    });

    test('a route that cannot be reached fails alone', () async {
      final dead = _FakeProbe(failWith: const TransportException('no route'));
      final live = _FakeProbe(pings: [5]);
      final results = await runConnectionTest([
        (ConnectionRoute.lan, dead),
        (ConnectionRoute.internet, live),
      ]);
      expect(results[0].failure, isNotNull);
      expect(results[0].latency, isNull);
      expect(results[1].failure, isNull);
      expect(dead.closed, isTrue);
    });

    test('a rate limit reads as a wait, not a broken route', () async {
      final limited = _FakeProbe(failWith: const RateLimitedException('slow'));
      final results =
          await runConnectionTest([(ConnectionRoute.internet, limited)]);
      expect(results.single.failure, contains('try again'));
    });

    test('progress only moves forward and ends complete', () async {
      final seen = <double>[];
      await runConnectionTest(
        [
          (ConnectionRoute.lan, _FakeProbe(pings: [1])),
          (ConnectionRoute.internet, _FakeProbe(pings: [1])),
        ],
        onProgress: (p) => seen.add(p.fraction),
      );
      expect([...seen]..sort(), seen);
      expect(seen.last, closeTo(1, 0.001));
    });

    test('cancelling stops the test with UploadCancelled', () async {
      final cancel = UploadCancelToken();
      final probe = _FakeProbe(pings: [1]);
      await expectLater(
        runConnectionTest(
          [(ConnectionRoute.internet, probe)],
          cancel: cancel,
          onProgress: (p) {
            if (p.fraction > 0.2) cancel.cancel();
          },
        ),
        throwsA(isA<UploadCancelled>()),
      );
      expect(probe.closed, isTrue);
    });
  });

  group('the API probe', () {
    late HttpServer server;
    late SlimmApi api;
    late List<String> seen;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      seen = [];
      server.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        expect(request.headers.value('authorization'), 'Bearer a');
        request.response.headers.set('cf-ray', 'abc');
        switch (request.uri.path) {
          case '/diagnostics/ping':
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'server_time_ms': 1}));
          case '/diagnostics/download':
            final n = int.parse(request.uri.queryParameters['bytes']!);
            request.response
              ..headers.contentLength = n
              ..add(List.filled(n, 1));
          case '/diagnostics/upload':
            var n = 0;
            await for (final chunk in request) {
              n += chunk.length;
            }
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'bytes': n, 'duration_ms': 3}));
        }
        await request.response.close();
      });
      api = SlimmApi(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'u',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
    });

    test('measures a ping, a download and an upload over the internet route',
        () async {
      final probes = api.connectionProbes();
      expect(probes.map((p) => p.$1), [ConnectionRoute.internet]);
      final probe = probes.single.$2;

      expect(await probe.ping(), isA<Duration>());
      final down = await probe.download(300000);
      expect(down.bytes, 300000);
      final progress = <int>[];
      final up = await probe.upload(200000, onProgress: progress.add);
      expect(up.bytes, 200000);
      expect(progress.last, 200000);
      expect(probe.viaCloudflare, isTrue);
      expect(seen, [
        'GET /diagnostics/ping',
        'GET /diagnostics/download',
        'POST /diagnostics/upload',
      ]);
      probe.close();
    });

    test('a refused transfer surfaces as the server\'s own error', () async {
      final probe = api.connectionProbes().single.$2;
      await server.close(force: true);
      await expectLater(probe.ping(), throwsA(isA<TransportException>()));
      probe.close();
    });
  });
}
