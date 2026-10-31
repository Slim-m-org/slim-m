// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A held connect queue only keeps the frames the store handler acts on, so the
/// handler's cases and `isAppliedToStore` must name the same event types.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/code_only.dart';

Set<String> _handlerCases() {
  final source = codeOnly(
    File('lib/src/sync/providers/sync_event_applier.dart').readAsStringSync(),
  );
  final start = source.indexOf('switch (event) {');
  final end = source.indexOf('case _:', start);
  expect(start, greaterThan(-1));
  expect(end, greaterThan(start));
  return RegExp(
    r'case\s+(\w+)\(',
  ).allMatches(source.substring(start, end)).map((m) => m.group(1)!).toSet();
}

Set<String> _listedTypes() {
  final source = codeOnly(
    File('lib/src/sync/providers/sync_frame_queue.dart').readAsStringSync(),
  );
  final start = source.indexOf('bool isAppliedToStore');
  final end = source.indexOf('};', start);
  expect(start, greaterThan(-1));
  return RegExp(
    r'api\.(\w+)\(',
  ).allMatches(source.substring(start, end)).map((m) => m.group(1)!).toSet();
}

void main() {
  test(
    'every event type the store handler acts on is held through a connect',
    () {
      final handled = _handlerCases();
      expect(handled, isNotEmpty);
      expect(
        handled.difference(_listedTypes()),
        isEmpty,
        reason:
            'a handled type missing from isAppliedToStore is dropped while held',
      );
    },
  );

  test('isAppliedToStore lists no type the handler ignores', () {
    expect(_listedTypes().difference(_handlerCases()), isEmpty);
  });
}
