// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whatever the socket loses, repeats or reorders, and however a catch-up's
/// answer interleaves with it, one quiet catch-up leaves the local store
/// agreeing with the server: no message missing, none stale, none that the
/// server deleted.
///
/// Seeded, so a failure names the seed that reproduces it; each finding is
/// also pinned in `sync_convergence_findings_test.dart`. The two-tab variant
/// is `sync_convergence_two_tabs_property_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/fuzz_budget.dart';
import '../support/sync_convergence_run.dart';

void main() {
  test('the store agrees with the server after any run of lost, repeated and '
      'reordered frames and delayed catch-ups', () async {
    final seeds = fuzzSeeds(full: 1000, quick: 150);
    for (var seed = 0; seed < seeds; seed++) {
      final wrong = await runSyncConvergence(seed);
      expect(wrong, isNull, reason: 'seed $seed: $wrong');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
