// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captures of the server switcher: the menu on a wide window, the sheet on a
/// phone, and the pill for a call on another server, in both themes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_call_pill.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_switcher.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_unread_badge.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';

import '../../ui_snapshot_support.dart';
import 'account_host_harness.dart';
import 'account_switcher_support.dart';

const _viewports = {'desktop': Size(1280, 800), 'phone': Size(390, 844)};

Widget _rail(bool wide) => Align(
  alignment: Alignment.topLeft,
  child: SizedBox(width: wide ? 280 : null, child: const RailHeader()),
);

void main() {
  for (final MapEntry(key: name, value: size) in _viewports.entries) {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      testWidgets('switcher open, $name, $theme', (tester) async {
        final h = await twoServers(tester, size: size);
        await tester.pumpWidget(
          HostRoot(
            host: h.host,
            dark: dark,
            boundary: snapshotBoundary,
            child: _rail(name == 'desktop'),
          ),
        );
        await seedUnread(tester, h, 'https://second.example', mention: true);
        await tester.tap(find.byKey(AccountSwitcherTrigger.triggerKey));
        await tester.pumpAndSettle();

        expect(find.byKey(AccountUnreadBadge.countKey), findsNWidgets(2));
        expect(find.text('Add a server'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'account_switcher_${name}_$theme');
      });
    }
  }

  testWidgets('call pill, desktop, light', (tester) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(
      HostRoot(
        host: h.host,
        boundary: snapshotBoundary,
        child: const Stack(
          children: [Positioned.fill(child: AccountCallPill())],
        ),
      ),
    );
    h.host
            .runtimeFor('https://first.example')!
            .container
            .read(testCallProvider.notifier)
            .state =
        connectedCall;
    await tester.pumpAndSettle();
    await h.host.switchTo('https://second.example');
    await tester.pumpAndSettle();

    expect(find.byKey(AccountCallPill.pillKey), findsOneWidget);
    await writeSnapshot(tester, 'account_call_pill_desktop_light');
  });
}
