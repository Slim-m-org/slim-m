// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The convergence property of `sync_convergence_property_test.dart` with two
/// tabs on one database, each behind the other at times. Its own file so the
/// shard dealer can place it apart from the one-tab run.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/fuzz_budget.dart';
import '../support/sync_convergence_run.dart';

void main() {
  test('two tabs on one database, each behind the other at times, still '
      'agree with the server', () async {
    final seeds = fuzzSeeds(full: 1000, quick: 150);
    for (var seed = 0; seed < seeds; seed++) {
      final wrong = await runSyncConvergence(seed, tabCount: 2);
      expect(wrong, isNull, reason: 'seed $seed: $wrong');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
