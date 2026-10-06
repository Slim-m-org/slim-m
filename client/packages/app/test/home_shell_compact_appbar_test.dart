// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone app bar must survive "Back to the call" into a real voice channel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/dm_call_pane.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/widgets/compact_channel_app_bar.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

void main() {
  /// The strip and rail summary set the DM-call provider for any channel, so a
  /// voice channel left it pointing there and later visits lost the app bar.
  testWidgets('a voice channel keeps its compact app bar after the call return', (
    tester,
  ) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(id: 'c1', name: 'lounge', kind: 'voice', createdAt: 0),
      const api.Channel(id: 'c2', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await pumpAtWidth(tester, s.container, 500, location: '/channels/c2');

    s.container.read(dmCallOpenProvider.notifier).state = 'c1';
    GoRouter.of(tester.element(find.byType(HomeShell))).go('/channels/c1');
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(HomeShell))).go('/channels/c2');
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(HomeShell))).go('/channels/c1');
    // Not settled: the revisited voice stage shows its connecting spinner, which never stops animating here.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(CompactChannelAppBar), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });
}
