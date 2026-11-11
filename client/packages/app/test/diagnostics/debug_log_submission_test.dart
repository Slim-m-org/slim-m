// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the debug log may carry out of the device: no credentials, no written
/// content, no addresses, and never more than the server takes.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/diagnostics/debug_log_submission.dart';

void main() {
  test('bearer tokens, keyed secrets and long opaque strings are gone', () {
    final out = scrubDebugLog(
      'GET /x Authorization: Bearer abc.def-ghi password=hunter2 '
      'refresh_token: "r3fresh" key ${'a1B2' * 12}',
    );
    for (final secret in ['abc.def-ghi', 'hunter2', 'r3fresh', 'a1B2a1B2']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('tickets, sessions and one-time codes are masked', () {
    final out = scrubDebugLog(
      '{"type":"hello","ticket":"t-123"} totp=654321 invite: SPRING-7',
    );
    for (final secret in ['t-123', '654321', 'SPRING-7']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('written content in a JSON body is masked, other fields stay', () {
    final out = scrubDebugLog(
      r'FormatException: {"id":"m1","content":"meet me at \"noon\"","seq":4}',
    );
    expect(out, isNot(contains('meet me')));
    expect(out, isNot(contains('noon')));
    expect(out, contains('"id":"m1"'));
    expect(out, contains('"seq":4'));
  });

  test('email addresses are masked', () {
    expect(
      scrubDebugLog('sent to nia@example.com failed'),
      isNot(contains('@')),
    );
  });

  test(
    'a record logged with a token in its context is scrubbed end to end',
    () {
      final log = DebugLog();
      addTearDown(log.dispose);
      log.write(
        LogRecord(
          at: DateTime(2026),
          level: LogLevel.error,
          tag: LogTag.ui,
          message: 'refresh failed',
          error: 'Bearer topsecret ticket=abc',
          context: const {'token': 'tok-1'},
        ),
      );
      final out = debugLogSubmission(log.asReport());
      expect(out, contains('refresh failed'));
      for (final secret in ['topsecret', 'abc', 'tok-1']) {
        expect(out, isNot(contains(secret)));
      }
    },
  );

  test('a log over the cap keeps its newest lines whole, within the cap', () {
    final report = [
      for (var i = 0; i < 100; i++) 'line $i ${'ab ' * 30}',
    ].join('\n');
    final out = debugLogSubmission(report, maxBytes: 1000);
    expect(utf8.encode(out).length, lessThanOrEqualTo(1000));
    expect(out, endsWith('line 99 ${'ab ' * 30}'));
    expect(out, isNot(contains('line 0 ')));
    expect(out.split('\n').first, startsWith('line '));
  });

  test('a log under the cap is sent as it is', () {
    expect(
      debugLogSubmission('12:00:00  ERROR  [ui]  broke'),
      '12:00:00  ERROR  [ui]  broke',
    );
  });
}
