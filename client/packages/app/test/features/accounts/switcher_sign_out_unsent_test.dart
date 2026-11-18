// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing out of a server from the switcher wipes that server's store too,
/// so it asks first, the same as Settings > Sign out, and counts that
/// server's unsent messages rather than the one on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_switcher.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'account_host_harness.dart';
import 'account_switcher_support.dart';

const _first = 'https://first.example';
const _second = 'https://second.example';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(pumpEventQueueTimes);
  }
  await tester.pump();
}

Future<AccountHarness> _withUnsentOnSecond(WidgetTester tester) async {
  final h = await twoServers(tester);
  await tester.runAsync(() async {
    final store = await h.host
        .runtimeFor(_second)!
        .container
        .read(storeProvider.future);
    await store.addPending(
      id: 'p1',
      channelId: 'c1',
      authorId: 'bea',
      content: 'not yet',
    );
  });
  await tester.pumpWidget(
    HostRoot(
      host: h.host,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: AccountSwitcherTrigger(child: Text('Home')),
      ),
    ),
  );
  await tester.tap(find.byKey(AccountSwitcherTrigger.triggerKey));
  await _settle(tester);
  await tester.tap(find.bySemanticsLabel('Sign out of Second'));
  await _settle(tester);
  return h;
}

void main() {
  testWidgets('Cancel keeps the server and its unsent message', (tester) async {
    final h = await _withUnsentOnSecond(tester);

    expect(
      find.text('1 message has not been sent yet. Signing out deletes it.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(h.host.accounts.map((r) => r.account!.origin), [_first, _second]);
  });

  testWidgets('confirming signs out of that server', (tester) async {
    final h = await _withUnsentOnSecond(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Sign out'));
    await _settle(tester);

    expect(h.host.accounts.map((r) => r.account!.origin), [_first]);
  });
}
