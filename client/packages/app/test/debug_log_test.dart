// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-app log's contract: bounded, redacted before it is kept, repeats
/// folded, and persisted across a restart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/diagnostics/debug_log_persistence.dart';

class _MemoryPersistence implements DebugLogPersistence {
  List<DiagnosticEvent> saved = const [];
  int saves = 0;

  @override
  Future<List<DiagnosticEvent>> load() async => saved;

  @override
  Future<void> save(List<DiagnosticEvent> events) async {
    saved = events;
    saves++;
  }
}

LogRecord _record(String message, {LogLevel level = LogLevel.info}) =>
    LogRecord(
      at: DateTime(2026, 10, 18),
      level: level,
      tag: LogTag.sync,
      message: message,
    );

void main() {
  tearDown(() => AppLog.install(null));

  test('keeps the newest records and drops the oldest past capacity', () {
    final log = DebugLog(capacity: 3);
    for (var i = 0; i < 5; i++) {
      log.write(_record('m$i'));
    }
    expect(log.state.map((e) => e.message), ['m4', 'm3', 'm2']);
  });

  test('folds identical consecutive records into one counted entry', () {
    final log = DebugLog();
    for (var i = 0; i < 4; i++) {
      log.write(_record('retrying'));
    }
    log.write(_record('other'));
    expect(log.state, hasLength(2));
    expect(log.state.last.count, 4);
  });

  test('a flood of debug records cannot push an error out of the ring', () {
    final log = DebugLog(capacity: 4)
      ..write(_record('boom', level: LogLevel.error));
    for (var i = 0; i < 20; i++) {
      log.write(_record('stat $i', level: LogLevel.debug));
    }
    expect(log.state.where((e) => e.level == LogLevel.error), hasLength(1));
    expect(log.state, hasLength(4));
  });

  test(
    'records installed through AppLog are redacted before they are kept',
    () {
      final log = DebugLog();
      AppLog.install(log);
      AppLog.error(
        LogTag.auth,
        'login failed password=hunter2',
        error: 'Bearer abc.def',
        context: {'token': 'tok', 'content': 'hello world', 'channel': 'c1'},
      );
      final text = log.asReport();
      for (final secret in ['hunter2', 'abc.def', 'tok\n', 'hello world']) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('channel=c1'));
    },
  );

  test(
    'the report is redacted again, so an old unredacted entry cannot leak',
    () {
      final log = DebugLog()
        ..state = [
          DiagnosticEvent(
            at: DateTime(2026),
            level: LogLevel.error,
            source: 'x',
            message: 'password=letmein',
          ),
        ];
      expect(log.asReport(), isNot(contains('letmein')));
    },
  );

  test('the log round-trips through its persisted form', () {
    final events = [
      DiagnosticEvent(
        at: DateTime(2026, 10, 18, 9, 30),
        level: LogLevel.warning,
        source: LogTag.push,
        message: 'Could not register',
        detail: 'TransportException: x',
        context: const {'kind': 'offline'},
        count: 3,
      ),
    ];
    final back = decodeEvents(encodeEvents(events)).single;
    expect(back.level, LogLevel.warning);
    expect(back.source, LogTag.push);
    expect(back.context, {'kind': 'offline'});
    expect(back.count, 3);
    expect(back.detail, 'TransportException: x');
  });

  test('persisted records are scrubbed again when they are read back', () {
    final raw = encodeEvents([
      DiagnosticEvent(
        at: DateTime(2026),
        level: LogLevel.error,
        source: 'x',
        message: 'token=abc123',
      ),
    ]);
    expect(decodeEvents(raw).single.message, isNot(contains('abc123')));
  });

  test('saves after a change and restores into a fresh log', () async {
    final disk = _MemoryPersistence();
    final first = DebugLog(
      persistence: disk,
      saveDelay: const Duration(milliseconds: 1),
    )..write(_record('before the crash', level: LogLevel.error));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(disk.saves, 1);

    final second = DebugLog(persistence: disk);
    await Future<void>.delayed(Duration.zero);
    expect(second.state.single.message, 'before the crash');
    first.dispose();
    second.dispose();
  });

  test('reportFailureSentence logs once and keeps the user sentence', () {
    final log = DebugLog();
    AppLog.install(log);
    final sentence = reportFailureSentence(
      LogTag.ui,
      'rename the channel',
      const TransportException('GET /x SocketException'),
    );
    expect(sentence, contains('Could not rename the channel'));
    expect(sentence, isNot(contains('SocketException')));
    expect(log.state, hasLength(1));
    expect(log.state.single.context['kind'], 'offline');
  });
}
