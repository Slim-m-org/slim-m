// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// First-run setup is a named dialog to a screen reader, with the shell under
/// it out of the tree until setup closes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_gate.dart';

import '../../support/semantics_audit.dart';
import 'first_run_harness.dart';

void main() {
  testWidgets('setup is a named dialog over a hidden shell', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpFirstRun(tester);

    expect(namedRoute(tester, firstRunDialogLabel), isNotNull);
    expect(
      announces(tester, 'shell'),
      isFalse,
      reason: 'the shell under setup must leave the tree',
    );

    await tester.tap(find.text('Skip setup'));
    await settle(tester);
    expect(announces(tester, 'shell'), isTrue);
    expect(namedRoute(tester, firstRunDialogLabel), isNull);
    handle.dispose();
  });
}
