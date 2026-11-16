// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What gives way to a starting call is waited for, but never holds the join
/// past its limit or over a failure, and a removed one is not run again.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_start_yields.dart';

void main() {
  test('every yield runs and is waited for', () async {
    final yields = CallStartYields();
    final done = <String>[];
    yields
      ..add(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        done.add('recording');
      })
      ..add(() async => done.add('playback'));

    await yields.callStarting();

    expect(done, unorderedEquals(['recording', 'playback']));
  });

  test('a yield that hangs or throws does not hold the call', () async {
    final yields = CallStartYields(limit: const Duration(milliseconds: 50))
      ..add(() => Completer<void>().future)
      ..add(() async => throw StateError('the encoder died'));

    await yields.callStarting().timeout(const Duration(seconds: 2));
  });

  test('a removed yield is not run', () async {
    final yields = CallStartYields();
    var runs = 0;
    final remove = yields.add(() async => runs++);

    remove();
    await yields.callStarting();

    expect(runs, 0);
  });
}
