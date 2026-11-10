// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves `withFixtureTeardown` disposes the fixture when its body fails, which
/// is the case a bare trailing `teardownFixture` call skips.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../ui_snapshot_support.dart';

void main() {
  testWidgets('disposes the container and rethrows when the body throws', (
    tester,
  ) async {
    final fixture = await fixtureContainer();
    final failure = StateError('the assertion under test failed');

    await expectLater(
      withFixtureTeardown(tester, fixture, () async => throw failure),
      throwsA(same(failure)),
    );

    expect(() => fixture.container.read(sessionProvider), throwsStateError);
  });

  testWidgets('disposes the container when the body completes', (tester) async {
    final fixture = await fixtureContainer();

    await withFixtureTeardown(tester, fixture, () async {});

    expect(() => fixture.container.read(sessionProvider), throwsStateError);
  });
}
