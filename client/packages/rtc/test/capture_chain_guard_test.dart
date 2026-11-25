// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A capture chain that fails goes out raw, waits, and is tried again later.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/capture_chain_guard.dart';

void main() {
  group('ChainRetry', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('is not failed until a failure and not due while it pauses', () {
      final retry = ChainRetry();
      expect(retry.failed, isFalse);
      expect(retry.due(t0), isFalse);

      retry.fail(t0);

      expect(retry.failed, isTrue);
      expect(retry.due(t0.add(const Duration(seconds: 29))), isFalse);
      expect(retry.due(t0.add(const Duration(seconds: 31))), isTrue);
    });

    test('clearing makes it healthy again', () {
      final retry = ChainRetry()..fail(t0);
      retry.clear();
      expect(retry.failed, isFalse);
    });
  });

  group('attachOrRaw', () {
    test('a throw gives back the raw track and reports it', () async {
      Object? reported;
      final out = await attachOrRaw<String>(
        attach: () async => throw StateError('no source'),
        raw: 'raw',
        timeout: const Duration(seconds: 2),
        onFailed: (error, _) => reported = error,
      );
      expect(out, 'raw');
      expect(reported, isA<StateError>());
    });

    test('a resume that never answers gives back the raw track', () {
      fakeAsync((async) {
        String? out;
        var failed = false;
        attachOrRaw<String>(
          attach: () => Completer<String>().future,
          raw: 'raw',
          timeout: const Duration(seconds: 2),
          onFailed: (e, s) => failed = true,
        ).then((v) => out = v);
        async.elapse(const Duration(seconds: 1));
        expect(out, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(out, 'raw');
        expect(failed, isTrue);
      });
    });

    test('a good attach is returned untouched', () async {
      var failed = false;
      final out = await attachOrRaw<String>(
        attach: () async => 'processed',
        raw: 'raw',
        timeout: const Duration(seconds: 2),
        onFailed: (e, s) => failed = true,
      );
      expect(out, 'processed');
      expect(failed, isFalse);
    });
  });

  test('only a context in use that is not running needs a resume', () {
    expect(contextNeedsResume('suspended', inUse: true), isTrue);
    expect(contextNeedsResume('interrupted', inUse: true), isTrue);
    expect(contextNeedsResume('running', inUse: true), isFalse);
    expect(contextNeedsResume('suspended', inUse: false), isFalse);
    expect(contextNeedsResume('closed', inUse: true), isFalse);
  });

  test('an element stays audible whenever its context is not running', () {
    expect(elementShouldBeMuted('running', resuming: false), isTrue);
    expect(elementShouldBeMuted('suspended', resuming: true), isTrue);
    expect(elementShouldBeMuted('suspended', resuming: false), isFalse);
    expect(elementShouldBeMuted('interrupted', resuming: false), isFalse);
  });
}
