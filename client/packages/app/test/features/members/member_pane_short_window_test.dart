// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A window too short to open the member pane by default (a phone in
/// landscape) keeps the conversation wide until the viewer opens the roster.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_header.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/home_shell_harness.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester,
  double width,
  double height,
) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(
    tester,
    s.container,
    width,
    height: height,
    location: '/channels/c1',
  );
  return s;
}

void main() {
  testWidgets('844x390 starts with the pane closed and the chat column wide', (
    tester,
  ) async {
    final s = await _open(tester, 844, 390);

    expect(find.byType(AppMemberPane), findsNothing);
    final chat = tester.getSize(find.byType(ChannelHeader)).width;
    expect(
      chat,
      greaterThan(844 / 2),
      reason: 'the chat column kept half the window at least: $chat',
    );

    await teardown(tester, s.container, s.db);
  });

  testWidgets('the header toggle still opens it on a short window', (
    tester,
  ) async {
    final s = await _open(tester, 1100, 390);
    final closedWidth = tester.getSize(find.byType(ChannelHeader)).width;
    expect(find.byType(AppMemberPane), findsNothing);

    await tester.tap(find.bySemanticsLabel('Toggle member list'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMemberPane), findsOneWidget);
    expect(
      tester.getSize(find.byType(ChannelHeader)).width,
      closedWidth - AppMemberPane.width,
    );

    await tester.tap(find.bySemanticsLabel('Toggle member list'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMemberPane), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('1280x720 still opens it by default', (tester) async {
    final s = await _open(tester, 1280, 720);

    expect(find.byType(AppMemberPane), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });
}
