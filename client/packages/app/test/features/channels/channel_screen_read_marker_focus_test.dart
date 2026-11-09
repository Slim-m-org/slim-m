// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An open channel is only marked read while somebody can actually be looking
/// at it: a window behind another app, or an account out of view, leaves the
/// channel unread so the account's other devices keep their badge, and the
/// moment the window is watched again the channel is marked read.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_data/data.dart';

import '../../channel_history_harness.dart';

final _focus = StateProvider<bool>((ref) => true);

Future<int> _lastReadSeq(SlimmDatabase db) async {
  final row = await (db.select(
    db.channels,
  )..where((c) => c.id.equals('c1'))).getSingle();
  return row.lastReadSeq;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<HistoryHarness> _mountUnfocused(WidgetTester tester) async {
  final h = await mountChannel(
    tester,
    serverSeqs: const [1, 2, 3],
    seededSeqs: const [1, 2, 3],
    overrides: [appFocusedProvider.overrideWith((ref) => ref.watch(_focus))],
  );
  return h;
}

void main() {
  testWidgets('a channel opened in an unfocused window stays unread until the '
      'window is focused', (tester) async {
    final h = await mountChannel(
      tester,
      serverSeqs: const [1, 2, 3],
      seededSeqs: const [1, 2, 3],
      overrides: [
        appFocusedProvider.overrideWith((ref) => ref.watch(_focus)),
        _focus.overrideWith((ref) => false),
      ],
    );

    expect(
      await _lastReadSeq(h.db),
      0,
      reason: 'nobody is looking at the window, so nothing has been read',
    );

    h.container.read(_focus.notifier).state = true;
    await flush(tester);

    expect(
      await _lastReadSeq(h.db),
      3,
      reason: 'focusing the window is when the newest message is first seen',
    );
    await _unmount(tester);
  });

  testWidgets('a message arriving in an unfocused window is not marked read '
      'until the window is focused', (tester) async {
    final h = await _mountUnfocused(tester);
    expect(await _lastReadSeq(h.db), 3);

    h.container.read(_focus.notifier).state = false;
    await flush(tester);
    await h.store.applyMessages([channelMessage(4)]);
    await flush(tester);

    expect(await _lastReadSeq(h.db), 3);

    h.container.read(_focus.notifier).state = true;
    await flush(tester);

    expect(await _lastReadSeq(h.db), 4);
    await _unmount(tester);
  });

  testWidgets('a channel in an account that is out of view is not marked '
      'read', (tester) async {
    final h = await mountChannel(
      tester,
      serverSeqs: const [1, 2, 3],
      seededSeqs: const [1, 2, 3],
      overrides: [accountActiveProvider.overrideWith((ref) => false)],
    );

    expect(await _lastReadSeq(h.db), 0);

    h.container.read(accountActiveProvider.notifier).state = true;
    await flush(tester);

    expect(await _lastReadSeq(h.db), 3);
    await _unmount(tester);
  });
}
