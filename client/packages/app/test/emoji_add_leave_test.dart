// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the emoji screen mid-upload: the remaining chunks still upload and
/// the cached emoji list is refreshed, because the writes outlive the card.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_add_harness.dart';

void main() {
  testWidgets('leaving mid-upload finishes every chunk and refreshes the list', (
    tester,
  ) async {
    final gates = <Completer<void>>[];
    var bulkCalls = 0;
    final h = EmojiHarness(
      picks: [for (var i = 0; i < 120; i++) emojiPick('e$i.png')],
      onBulk: (r) =>
          emojiJson([for (final n in bulkNames(r)) emojiRow(n)], status: 201),
    );
    final container = await h.pump(tester);
    // The composer keeps the provider alive, as the original finding describes.
    final sub = container.listen(customEmojiProvider, (_, _) {});
    addTearDown(sub.close);
    await h.choose(tester);

    // Hold each bulk response open so the card can be removed mid-flight.
    h.holdBulk = (r) async {
      bulkCalls++;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    };
    await tester.tap(find.text('Add 120 emoji'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(bulkCalls, 1);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const SizedBox(),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (gates.length > i) gates[i].complete();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(bulkCalls, 3, reason: 'every chunk is still sent after leaving');
    expect(h.listFetches, greaterThan(1), reason: 'the cached list is stale');
    expect(tester.takeException(), isNull);
  });
}
