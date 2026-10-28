// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// No new `StateNotifier` subclass: riverpod 3 moves it to a legacy import,
/// so each new one raises the cost of the upgrade. Write a `Notifier` or
/// `AsyncNotifier`. Existing ones are listed in `state_notifier_allow.txt`
/// and may only shrink; `docs/notifier-migration.md` has the plan.
library;

import 'package:flutter_test/flutter_test.dart';

import 'ratchet_support.dart';

const _allowlist = 'test/state_notifier_allow.txt';

void main() {
  test('no new StateNotifier, and migrated ones leave the list', () {
    final found = countByFile(
      'lib/src',
      RegExp(r'\bextends\s+StateNotifier\s*<'),
    );
    expectRatchet(
      found,
      readAllowlist(_allowlist),
      what: 'a class extends StateNotifier',
      allowlist: _allowlist,
    );
  });
}
