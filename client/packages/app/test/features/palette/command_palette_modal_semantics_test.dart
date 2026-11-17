// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette is a named dialog to a screen reader, with the shell behind it
/// out of the tree until it closes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';
import '../../support/semantics_audit.dart';

void main() {
  testWidgets('the open palette is a named dialog over a hidden shell', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final setup = setupPalette();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pump(tester, setup.container);
    expect(announces(tester, 'conversation'), isTrue);

    await pressCtrlK(tester);

    expect(namedRoute(tester, 'Command palette'), isNotNull);
    expect(
      announces(tester, 'conversation'),
      isFalse,
      reason: 'the shell behind the palette must leave the tree',
    );

    handle.dispose();
    await teardown(tester, setup.container, setup.db);
  });
}
