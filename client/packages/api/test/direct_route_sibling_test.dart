// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host beside the server's, such as the call's signalling, takes the
/// advertised address too, but only while requests do and only when the proxy
/// there proves it serves that host; otherwise the caller connects normally.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:slimm_api/api.dart' show AppLog, LogRecord, LogSink;
import 'package:slimm_api/src/direct_route.dart' show siblingHost;
import 'package:slimm_api/src/direct_route_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/status.dart' as status;

const _fixtures = 'test/fixtures/direct_route';
const _host = 'slimm.test';
const _sibling = 'livekit.slimm.test';
const _port = 8443;
const _base = 'https://$_host:$_port';
const _lan = '127.0.0.1:$_port';
const _signal = 'wss://$_sibling:$_port/rtc';

/// Where the generated proxy certificate lives; see [_generateProxyCert].
late final Directory _generated;

late final SecurityContext _trusting;

/// The committed fixtures, or the generated proxy certificate for `proxy`.
SecurityContext _serving(String name) {
  final dir = name == 'proxy' ? _generated.path : _fixtures;
  return SecurityContext()
    ..useCertificateChain('$dir/$name.pem')
    ..usePrivateKey('$dir/$name.key');
}

/// A CA and one certificate naming both hosts, as a reverse proxy holds.
/// Made per run, so no private key is committed (the pre-commit guard rejects one).
Future<void> _generateProxyCert() async {
  _generated = Directory.systemTemp.createTempSync('slimm-proxy-cert-');
  final dir = _generated.path;
  Future<void> openssl(String args) async {
    final result = await Process.run(
      'openssl',
      args.split(' '),
      workingDirectory: dir,
    );
    if (result.exitCode != 0) fail('openssl $args: ${result.stderr}');
  }

  const key = '-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes';
  await openssl(
    'req -x509 $key -keyout ca.key -out ca.pem -days 2 '
    '-subj /CN=slim-m-test-proxy-CA '
    '-addext basicConstraints=critical,CA:TRUE '
    '-addext keyUsage=critical,keyCertSign',
  );
  await openssl('req $key -keyout proxy.key -out proxy.csr -subj /CN=$_host');
  File('$dir/proxy.ext').writeAsStringSync(
    'subjectAltName=DNS:$_host,DNS:$_sibling\n'
    'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n',
  );
  await openssl(
    'x509 -req -in proxy.csr -CA ca.pem -CAkey ca.key -CAcreateserial '
    '-out proxy.pem -days 2 -extfile proxy.ext',
  );
  _trusting = SecurityContext()
    ..setTrustedCertificates('$_fixtures/ca.pem')
    ..setTrustedCertificates('$dir/ca.pem');
}

/// A TLS server answering requests and socket upgrades with [label] and the Host it was asked for.
Future<(HttpServer, List<String>)> _server(String label, String cert) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    _serving(cert),
  );
  final seen = <String>[];
  server.listen((request) async {
    final host = request.headers.value(HttpHeaders.hostHeader) ?? '';
    seen.add('$host${request.uri.path}');
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final auth = request.headers.value('authorization') ?? '';
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('$label $host $auth');
      await socket.close();
      return;
    }
    request.response.write(label);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return (server, seen);
}

class _Capture implements LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  setUpAll(_generateProxyCert);
  tearDownAll(() => _generated.deleteSync(recursive: true));

  late HttpServer public;
  late DateTime now;
  late int directTarget;
  late int dials;

  setUp(() async {
    (public, _) = await _server('public', _host);
    now = DateTime(2026);
    directTarget = 1;
    dials = 0;
  });

  IoDirectRoute route({String base = _base}) {
    final route = IoDirectRoute(
      Uri.parse(base),
      context: _trusting,
      connectPublic: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, public.port),
      connectDirect: (host, port) {
        dials++;
        return Socket.connect(InternetAddress.loopbackIPv4, directTarget);
      },
      clock: () => now,
    );
    addTearDown(route.httpClient.close);
    return route;
  }

  /// A route whose requests already go over the advertised address, at a proxy holding [cert].
  Future<(IoDirectRoute, List<String>)> onLan(
    String cert, {
    String base = _base,
    String lan = _lan,
  }) async {
    final (proxy, seen) = await _server('direct', cert);
    directTarget = proxy.port;
    final r = route(base: base)..advertise([lan]);
    await r.httpClient.get(Uri.parse('$base/version'));
    expect(r.active, isTrue);
    return (r, seen);
  }

  Future<String?> open(IoDirectRoute r, String url) async {
    final channel = await r.connectSiblingDirect(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer t'},
    );
    if (channel == null) return null;
    final first = await channel.stream.first as String;
    await channel.sink.close(status.normalClosure);
    return first;
  }

  test(
      'a sibling host the proxy serves opens over the advertised address, '
      'with TLS, the Host header and the headers asked for', () async {
    final (r, seen) = await onLan('proxy');

    expect(await open(r, _signal), 'direct $_sibling:$_port Bearer t');
    expect(seen.last, '$_sibling:$_port/rtc');
  });

  test('the server host itself is taken, and a URL without a port means 443',
      () async {
    final (r, _) = await onLan('proxy');
    expect(await open(r, 'wss://$_host:$_port/rtc'), startsWith('direct'));

    final (onDefault, _) = await onLan(
      'proxy',
      base: 'https://$_host',
      lan: '127.0.0.1:443',
    );
    expect(await open(onDefault, 'wss://$_sibling/rtc'), startsWith('direct'));
  });

  test('nothing is dialled while requests go the public way', () async {
    final (proxy, _) = await _server('direct', 'proxy');
    directTarget = proxy.port;
    final r = route()..advertise([_lan]);

    expect(await open(r, _signal), isNull);
    expect(dials, 0);
  });

  test(
      'a host that is not beside the server, a plain socket, another port '
      'or a URL that is no socket is never dialled', () async {
    final (r, _) = await onLan('proxy');
    final before = dials;

    expect(await open(r, 'wss://livekit.other.test:$_port/rtc'), isNull);
    expect(await open(r, 'ws://$_sibling:$_port/rtc'), isNull);
    expect(await open(r, 'wss://$_sibling:7880/rtc'), isNull);
    expect(await open(r, 'wss://$_sibling/rtc'), isNull);
    expect(await open(r, 'wss://127.0.0.1:$_port/rtc'), isNull);
    expect(await open(r, 'https://$_sibling:$_port/rtc'), isNull);
    expect(dials, before);
    expect(await open(r, _signal), startsWith('direct'), reason: 'no back-off');
  });

  test(
      'a proxy that does not hold the sibling host is refused before any '
      'request, and left alone for a while', () async {
    final (r, seen) = await onLan(_host);
    final before = dials;

    expect(await open(r, _signal), isNull);
    expect(dials, before + 1);
    expect(seen.where((s) => s.startsWith(_sibling)), isEmpty);

    expect(await open(r, _signal), isNull);
    expect(dials, before + 1, reason: 'still backing off');
    expect(r.active, isTrue, reason: 'requests keep their own route');

    now = now.add(const Duration(minutes: 2));
    await open(r, _signal);
    expect(dials, before + 2);
  });

  test('a proxy that never answers the upgrade gives up in time', () async {
    final hung = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      _serving('proxy'),
    );
    addTearDown(() => hung.close(force: true));
    final held = <HttpRequest>[];
    hung.listen((request) {
      if (request.uri.path == '/version') {
        request.response.write('direct');
        unawaited(request.response.close());
      } else {
        held.add(request);
      }
    });
    directTarget = hung.port;
    final r = route()..advertise([_lan]);
    await r.httpClient.get(Uri.parse('$_base/version'));
    expect(r.active, isTrue);

    final watch = Stopwatch()..start();
    expect(await open(r, _signal), isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(held, hasLength(1));
  });

  test('a failure is logged without the advertised address', () async {
    final capture = _Capture();
    AppLog.install(capture);
    addTearDown(() => AppLog.install(null));
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    directTarget = closed.port;
    await closed.close();
    final r = route()..advertise([_lan]);

    await r.httpClient.get(Uri.parse('$_base/a'));

    final lines = [
      for (final record in capture.records)
        '${record.message} ${record.error} ${record.context}',
    ];
    expect(lines, isNotEmpty);
    expect(lines.where((l) => l.contains('127.0.0.1')), isEmpty);
  });

  group('siblingHost', () {
    test('takes the host, a subdomain and a sibling under its parent', () {
      expect(siblingHost('slim.example.com', 'slim.example.com'), isTrue);
      expect(siblingHost('lk.slim.example.com', 'slim.example.com'), isTrue);
      expect(siblingHost('livekit.example.com', 'slim.example.com'), isTrue);
    });

    test('refuses other domains, a bare suffix and IP literals', () {
      expect(siblingHost('livekit.other.com', 'slim.example.com'), isFalse);
      expect(siblingHost('example.com', 'slim.example.com'), isFalse);
      expect(siblingHost('livekit.com', 'example.com'), isFalse);
      expect(siblingHost('badexample.com', 'example.com'), isFalse);
      expect(siblingHost('10.0.0.5', '10.0.0.100'), isFalse);
      expect(siblingHost('fd00::2', 'fd00::1'), isFalse);
    });
  });
}
