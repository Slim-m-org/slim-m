// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One lock per database, so a second account in a tab still gets its sweep.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

class _FakeLocks implements TabLockManager {
  final held = <String>{};
  Object? failWith;

  @override
  void requestIfAvailable(
    String name,
    void Function(bool granted) onResult,
    void Function(Object error) onError,
  ) {
    final error = failWith;
    if (error != null) return onError(error);
    onResult(held.add(name));
  }
}

void main() {
  test('two accounts in one tab each claim their own database', () async {
    final locks = _FakeLocks();

    expect(await claimSoleTabWith(locks, 'a.sqlite'), isTrue);
    expect(await claimSoleTabWith(locks, 'b.sqlite'), isTrue);
  });

  test('a rebuilt container for a claimed database does not claim again',
      () async {
    final locks = _FakeLocks();
    await claimSoleTabWith(locks, 'a.sqlite');

    expect(await claimSoleTabWith(locks, 'a.sqlite'), isFalse);
  });

  test('a rejected lock request resolves false instead of hanging', () async {
    final locks = _FakeLocks()..failWith = StateError('not active');

    expect(await claimSoleTabWith(locks, 'a.sqlite'), isFalse);
  });

  test('without a lock manager the tab is the sole one', () async {
    expect(await claimSoleTabWith(null, 'a.sqlite'), isTrue);
  });
}
