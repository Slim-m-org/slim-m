// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each account keeps and sends only its own debug records, and loses them at sign-out.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/diagnostics/debug_log_persistence.dart';
import 'package:slimm_app/src/diagnostics/debug_log_router.dart';

DebugLog _log(String origin, {DebugLogPersistence? persistence}) =>
    DebugLog(origin: () => origin, persistence: persistence);

void main() {
  tearDown(() => AppLog.install(null));

  test('a record stamped for one account never reaches another', () {
    final router = DebugLogRouter();
    final a = _log('https://a.example');
    final b = _log('https://b.example');
    router
      ..add(a)
      ..add(b);
    AppLog.install(router);

    AppLog.scoped(
      () => 'https://b.example',
      () => AppLog.error(LogTag.net, 'failed uri=https://b.example/channels/1'),
    );
    AppLog.info(LogTag.ui, 'shared record');

    expect(a.asReport(), isNot(contains('b.example')));
    expect(a.asReport(), contains('shared record'));
    expect(b.asReport(), contains('b.example'));
  });

  test('background work started inside a scope keeps its account', () async {
    final router = DebugLogRouter();
    final a = _log('https://a.example');
    final b = _log('https://b.example');
    router
      ..add(a)
      ..add(b);
    AppLog.install(router);

    await AppLog.scoped(() => 'https://b.example', () async {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      AppLog.warning(LogTag.sync, 'later failure');
    });

    expect(a.state, isEmpty);
    expect(b.state, hasLength(1));
  });

  test('a removed log stops receiving records', () {
    final router = DebugLogRouter();
    final a = _log('https://a.example');
    router.add(a);
    AppLog.install(router);
    router.remove(a);
    AppLog.info(LogTag.ui, 'after');
    expect(a.state, isEmpty);
  });

  group('saved copy', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('is kept per account', () async {
      final a = PrefsDebugLogPersistence(origin: () => 'https://a.example');
      final b = PrefsDebugLogPersistence(origin: () => 'https://b.example');
      final event = DiagnosticEvent(
        at: DateTime(2026),
        level: LogLevel.error,
        source: LogTag.net,
        message: 'only for a',
      );
      await a.save([event]);

      expect(await a.load(), hasLength(1));
      expect(await b.load(), isEmpty);
    });

    test('the old shared copy is dropped, not handed to an account', () async {
      SharedPreferences.setMockInitialValues({'debug_log.v1': '[]'});
      await PrefsDebugLogPersistence(origin: () => 'https://a.example').load();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('debug_log.v1'), isFalse);
    });

    test('erase empties the log and its saved copy at once', () async {
      final persistence = PrefsDebugLogPersistence(
        origin: () => 'https://a.example',
      );
      final log = _log('https://a.example', persistence: persistence)
        ..write(
          LogRecord(
            at: DateTime(2026),
            level: LogLevel.error,
            tag: LogTag.net,
            message: 'boom',
          ),
        );
      log.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await persistence.load(), isNotEmpty);

      await log.erase();

      expect(log.state, isEmpty);
      expect(await persistence.load(), isEmpty);
    });

    test('only the newest records are kept, with their detail cut', () async {
      final persistence = PrefsDebugLogPersistence(
        origin: () => 'https://a.example',
      );
      await persistence.save([
        for (var i = 0; i < 600; i++)
          DiagnosticEvent(
            at: DateTime(2026),
            level: LogLevel.error,
            source: LogTag.net,
            message: 'm$i',
            detail: 'x' * 5000,
          ),
      ]);
      final loaded = await persistence.load();
      expect(loaded, hasLength(PrefsDebugLogPersistence.maxEvents));
      expect(loaded.first.message, 'm0');
      expect(
        loaded.first.detail!.length,
        lessThanOrEqualTo(PrefsDebugLogPersistence.maxDetail),
      );
    });
  });
}
