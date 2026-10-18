// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

class _Capture implements LogSink {
  final records = <LogRecord>[];
  @override
  void write(LogRecord record) => records.add(record);
}

void main() {
  tearDown(() => AppLog.install(null));

  group('redaction', () {
    test('masks bearer tokens, jwts and keyed secrets in text', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl';
      final out = redactText(
        'GET /x Authorization: Bearer abc.def-ghi password=hunter2 '
        'refresh_token":"zzz" jwt $jwt',
      );
      expect(out, isNot(contains('abc.def-ghi')));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('zzz')));
      expect(out, isNot(contains(jwt)));
    });

    test('masks long opaque tokens but keeps uuids', () {
      const uuid = '0190f5c2-7a3e-7c1e-8c1a-1d2e3f4a5b6c';
      final out = redactText('id $uuid key ${'a1B2' * 12}');
      expect(out, contains(uuid));
      expect(out, isNot(contains('a1B2a1B2')));
    });

    test('masks sensitive context keys and scrubs the rest', () {
      final out = redactContext({
        'Content': 'hello there',
        'reset_code': 'ABC',
        'channel': 'c1',
        'note': 'token=secretvalue',
      });
      expect(out['Content'], redactedMark);
      expect(out['reset_code'], redactedMark);
      expect(out['channel'], 'c1');
      expect(out['note'], isNot(contains('secretvalue')));
    });
  });

  group('AppLog', () {
    test('redacts before the sink sees anything', () {
      final sink = _Capture();
      AppLog.install(sink);
      AppLog.error(
        LogTag.auth,
        'login password=abc123',
        error: Exception('Bearer topsecret'),
        context: {'token': 'x', 'channel': 'c'},
      );
      final r = sink.records.single;
      expect(r.message, isNot(contains('abc123')));
      expect(r.error, isNot(contains('topsecret')));
      expect(r.context['token'], redactedMark);
      expect(r.context['channel'], 'c');
    });

    test('buffers before a sink exists, bounded, then replays', () {
      for (var i = 0; i < 150; i++) {
        AppLog.info(LogTag.ui, 'm$i');
      }
      final sink = _Capture();
      AppLog.install(sink);
      expect(sink.records, hasLength(100));
      expect(sink.records.first.message, 'm50');
      expect(sink.records.last.message, 'm149');
    });

    test('swallowed logs at debug with the reason', () {
      final sink = _Capture();
      AppLog.install(sink);
      AppLog.swallowed(LogTag.media, 'cleanup is best effort', 'boom');
      expect(sink.records.single.level, LogLevel.debug);
      expect(sink.records.single.message, 'cleanup is best effort');
    });
  });

  group('classification', () {
    test('maps each failure to the kind the UI branches on', () {
      expect(classifyFailureKind(const TransportException('x')),
          FailureKind.offline);
      expect(classifyFailureKind(TimeoutException('t')), FailureKind.offline);
      expect(classifyFailureKind(const UnavailableException('x')),
          FailureKind.offline);
      expect(classifyFailureKind(const UnauthorizedException('x')),
          FailureKind.authExpired);
      expect(classifyFailureKind(const ForbiddenException('x')),
          FailureKind.refused);
      expect(classifyFailureKind(const BadRequestException('x')),
          FailureKind.refused);
      expect(classifyFailureKind(const ServerException('x', 500)),
          FailureKind.refused);
      expect(classifyFailureKind(StateError('x')), FailureKind.unexpected);
    });

    test('reportFailure logs once, warning for expected and error for bugs',
        () {
      final sink = _Capture();
      AppLog.install(sink);
      final offline =
          reportFailure(LogTag.sync, 'sync', const TransportException('x'));
      final bug = reportFailure(LogTag.sync, 'sync', StateError('x'));
      expect(
          sink.records.map((r) => r.level), [LogLevel.warning, LogLevel.error]);
      expect(sink.records.first.context['kind'], 'offline');
      expect(offline.retryable, isTrue);
      expect(bug.retryable, isFalse);
    });
  });
}
