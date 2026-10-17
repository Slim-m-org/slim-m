// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resumable uploads against a fake server that behaves like the real one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

/// Keeps what each PUT delivered, the way the real server's session file does.
class _FakeServer {
  _FakeServer({this.partMax = 64});

  final int partMax;
  final received = <int>[];
  final putOffsets = <int>[];
  final calls = <String>[];
  int size = 0;
  bool open = false;
  bool discarded = false;
  bool completed = false;
  var creates = 0;

  /// While above zero, each request gets the plain 404 a proxy gives for a
  /// backend that is restarting, and counts it down.
  int downFor = 0;

  /// The session is gone, as after the server's sweep: a JSON 404.
  bool gone = false;

  /// Called with the 1-based PUT number; may return an action for that PUT.
  _Fault? Function(int put)? fault;
  var _puts = 0;

  Map<String, dynamic> _session() => {
        'id': 'up1',
        'size': size,
        'offset': received.length,
        'part_max_bytes': partMax,
        'expires_at': 0,
      };

  http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    if (downFor > 0) {
      downFor--;
      return http.Response('404 page not found', 404);
    }
    if (request.method == 'GET' && path == '/version') {
      return _json({
        'name': 'slimm',
        'version': '1.0.0',
        'protocol': 1,
        'capabilities': ['upload_sessions'],
      });
    }
    if (request.method == 'POST' && path == '/attachments/uploads') {
      size = (jsonDecode(request.body) as Map<String, dynamic>)['size'] as int;
      open = true;
      gone = false;
      creates++;
      received.clear();
      return _json(_session(), 201);
    }
    if (gone && path.startsWith('/attachments/uploads/')) {
      return _json({'error': 'upload session not found'}, 404);
    }
    if (request.method == 'GET' && path == '/attachments/uploads/up1') {
      return _json(_session());
    }
    if (request.method == 'DELETE') {
      discarded = true;
      return http.Response('', 204);
    }
    if (request.method == 'POST' && path.endsWith('/complete')) {
      if (received.length != size) return _json({'error': 'short'}, 409);
      completed = true;
      return _json({
        'id': 'att1',
        'filename': 'big.iso',
        'content_type': 'application/octet-stream',
        'size': size,
      }, 201);
    }
    if (request.method == 'PUT') return _put(request);
    return http.Response('', 404);
  }

  Future<http.Response> _put(http.Request request) async {
    final offset = int.parse(request.url.queryParameters['offset']!);
    putOffsets.add(offset);
    final fault = this.fault?.call(++_puts);
    if (offset != received.length) return _json({'error': 'offset'}, 409);
    final body = request.bodyBytes;
    if (body.length > partMax) return _json({'error': 'part'}, 413);
    if (fault?.kind == _FaultKind.dropAfter) {
      received.addAll(body.take(fault!.keep));
      throw http.ClientException('connection reset');
    }
    if (fault?.kind == _FaultKind.status) {
      return _json({'error': 'boom'}, fault!.status);
    }
    received.addAll(body);
    return _json(_session());
  }
}

enum _FaultKind { dropAfter, status }

class _Fault {
  const _Fault.dropAfter(this.keep)
      : kind = _FaultKind.dropAfter,
        status = 0;
  const _Fault.status(this.status)
      : kind = _FaultKind.status,
        keep = 0;

  final _FaultKind kind;
  final int keep;
  final int status;
}

SlimmApi _api(_FakeServer server) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(server.handle),
    );

Uint8List _bytes(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) & 0xff));

UploadSource _source(Uint8List data, {bool seekable = false}) => UploadSource(
      open: () => Stream.fromIterable(
        [
          for (var i = 0; i < data.length; i += 10)
            data.sublist(i, _min(i + 10, data.length))
        ],
      ),
      openAt: seekable ? (offset) => Stream.value(data.sublist(offset)) : null,
    );

int _min(int a, int b) => a < b ? a : b;

Future<Attachment> _run(
  _FakeServer server,
  Uint8List data, {
  void Function(int)? onProgress,
  void Function(bool)? onRetrying,
  UploadCancelToken? cancel,
  bool seekable = false,
  int partBytes = 30,
  SlimmApi? api,
  String? resumeKey,
  List<String>? capabilities = const ['upload_sessions'],
  Duration stallLimit = const Duration(milliseconds: 200),
}) =>
    (api ?? _api(server)).uploadAttachmentAuto(
      _source(data, seekable: seekable),
      length: data.length,
      capabilities: capabilities,
      sessionThreshold: 0,
      filename: 'big.iso',
      onProgress: onProgress,
      onRetrying: onRetrying,
      cancel: cancel,
      resumeKey: resumeKey,
      backoff: (_) => const Duration(milliseconds: 5),
      stallLimit: stallLimit,
      partBytes: partBytes,
    );

void main() {
  test('sends every part in order and reports cumulative progress', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    final progress = <int>[];
    final attachment = await _run(server, data, onProgress: progress.add);
    expect(attachment.id, 'att1');
    expect(server.received, data);
    expect(server.putOffsets, [0, 30, 60, 90]);
    expect(progress.last, 100);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(server.discarded, isFalse);
  });

  test('never sends a part larger than the server allows', () async {
    final server = _FakeServer(partMax: 25);
    final data = _bytes(100);
    await _run(server, data, partBytes: 1000);
    expect(server.received, data);
    expect(server.putOffsets, [0, 25, 50, 75]);
  });

  test('a part whose reply was lost resumes from the server offset', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    // The first part lands but its reply is lost as a 503.
    server.fault = (put) {
      if (put != 1) return null;
      server.received.addAll(data.sublist(0, 30));
      return const _Fault.status(503);
    };
    final attachment = await _run(server, data);
    expect(attachment.id, 'att1');
    expect(server.received, data);
    // The retry starts at the server's 30, never rewriting the first part.
    expect(server.putOffsets, [0, 30, 60, 90]);
  });

  test('a 409 re-reads the offset and resumes from the server', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    // Another tab's part moved the server on before this PUT arrived.
    server.fault = (put) {
      if (put == 1) server.received.addAll(data.sublist(0, 30));
      return null;
    };
    await _run(server, data);
    expect(server.received, data);
    expect(server.putOffsets, [0, 30, 60, 90]);
    expect(server.calls, contains('GET /attachments/uploads/up1'));
  });

  for (final seekable in [false, true]) {
    test(
        'a dropped part resumes from what the server kept (seekable: '
        '$seekable)', () async {
      final server = _FakeServer()
        ..fault = (put) => put == 2 ? const _Fault.dropAfter(12) : null;
      final data = _bytes(100);
      final attachment = await _run(server, data, seekable: seekable);
      expect(attachment.id, 'att1');
      expect(server.received, data);
      expect(server.putOffsets, [0, 30, 42, 72]);
    });
  }

  test(
      'keeps retrying until the stall limit, then gives up without throwing '
      'the session away', () async {
    final server = _FakeServer()..fault = (_) => const _Fault.status(502);
    final watch = Stopwatch()..start();
    await expectLater(
      _run(server, _bytes(100), resumeKey: 'tile-1'),
      throwsA(isA<ServerException>()),
    );
    await pumpEventQueue();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
    expect(server.putOffsets.length, greaterThan(6));
    expect(server.discarded, isFalse, reason: 'a retry can still resume it');
  });

  test('rides out a server restart behind a proxy (issue: deploy mid-upload)',
      () async {
    final server = _FakeServer();
    final data = _bytes(100);
    final retrying = <bool>[];
    server.fault = (put) {
      if (put == 2) server.downFor = 6;
      return null;
    };
    final attachment = await _run(server, data, onRetrying: retrying.add);
    expect(attachment.id, 'att1');
    expect(server.received, data);
    expect(retrying, [true, false]);
    expect(server.creates, 1);
  });

  test('a session the server lost is started over once, not failed', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    server.fault = (put) {
      if (put == 2) server.gone = true;
      return null;
    };
    final attachment = await _run(server, data);
    expect(attachment.id, 'att1');
    expect(server.creates, 2);
    expect(server.received, data);
  });

  test(
      'a retry with the same resume key carries on where the last one '
      'stopped', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    final api = _api(server);
    server.fault = (put) => put >= 3 ? const _Fault.status(503) : null;
    await expectLater(
      _run(server, data, api: api, resumeKey: 'tile-1'),
      throwsA(isA<UnavailableException>()),
    );
    expect(server.received.length, 60);

    server.fault = null;
    final attachment = await _run(server, data, api: api, resumeKey: 'tile-1');
    expect(attachment.id, 'att1');
    expect(server.creates, 1, reason: 'resumed, not restarted');
    expect(server.received, data);
  });

  test('unknown capabilities are asked for rather than read as none', () async {
    final server = _FakeServer();
    final attachment = await _run(server, _bytes(100), capabilities: null);
    expect(attachment.id, 'att1');
    expect(server.calls, contains('GET /version'));
    expect(server.creates, 1);
  });

  test('a refusal that no retry can fix fails at once', () async {
    final server = _FakeServer()..fault = (_) => const _Fault.status(507);
    await expectLater(
      _run(server, _bytes(100)),
      throwsA(isA<ServerException>()),
    );
    await pumpEventQueue();
    expect(server.putOffsets.length, 1);
    expect(server.discarded, isTrue);
  });

  test('cancelling discards the session and stops sending', () async {
    final server = _FakeServer();
    final data = _bytes(100);
    final cancel = UploadCancelToken();
    final done = _run(
      server,
      data,
      cancel: cancel,
      onProgress: (sent) {
        if (sent >= 30) cancel.cancel();
      },
    );
    await expectLater(done, throwsA(isA<UploadCancelled>()));
    await pumpEventQueue();
    expect(server.discarded, isTrue);
    expect(server.completed, isFalse);
    expect(server.received.length, lessThan(100));
  });

  group('choosing single request or sessions', () {
    const withSessions = ['upload_sessions'];
    const big = kUploadSessionThreshold + 1;

    test('uses sessions above the threshold when advertised', () {
      expect(
        usesUploadSessions(length: big, capabilities: withSessions),
        isTrue,
      );
    });

    test('keeps one request at or below the threshold', () {
      expect(
        usesUploadSessions(
          length: kUploadSessionThreshold,
          capabilities: withSessions,
        ),
        isFalse,
      );
    });

    test('keeps one request when the server does not advertise sessions', () {
      expect(usesUploadSessions(length: big, capabilities: const []), isFalse);
      expect(usesUploadSessions(length: big, capabilities: null), isFalse);
    });

    test('uploadAttachmentAuto sends a small file as one POST /attachments',
        () async {
      final server = _FakeServer();
      final api = SlimmApi(
        baseUrl: _base,
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'u',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
        httpClient: MockClient((request) async {
          server.calls.add('${request.method} ${request.url.path}');
          return http.Response(
            jsonEncode({
              'id': 'single',
              'filename': 'a.bin',
              'content_type': 'application/octet-stream',
              'size': 3,
            }),
            201,
          );
        }),
      );
      final attachment = await api.uploadAttachmentAuto(
        UploadSource(open: () => Stream.value([1, 2, 3])),
        length: 3,
        capabilities: withSessions,
      );
      expect(attachment.id, 'single');
      expect(server.calls, ['POST /attachments']);
    });
  });
}
