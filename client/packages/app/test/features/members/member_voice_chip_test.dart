// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "in #voice" chip: shown on a member row and card only while the member
/// is in a visible call, and a tap jumps to that channel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/members/widgets/member_voice_chip.dart';
import 'package:slimm_app/src/features/voice/providers/member_voice_channel.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../voice/member_voice_channel_test.dart' show voiceChannel;

const _ada = api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
);

Future<GoRouter> _pump(
  WidgetTester tester, {
  Channel? inChannel,
  Widget? body,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: body ?? const MemberRow(profile: _ada, isSelf: false),
        ),
      ),
      GoRoute(
        path: Routes.channel(':id'),
        builder: (_, state) => Text('opened ${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        liveEventsProvider.overrideWithValue(
          const Stream<api.ServerEvent>.empty(),
        ),
        memberVoiceChannelProvider('ada').overrideWithValue(inChannel),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return router;
}

const _mod = api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Bartholomew Featherstonehaugh',
  createdAt: 0,
  roleIds: ['r'],
  roles: ['Moderator'],
);

Future<void> _pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pump(
    tester,
    inChannel: voiceChannel('v1', 'movie-room-late-night'),
    body: const MemberRow(profile: _mod, isSelf: false),
  );
}

void main() {
  testWidgets('in the 236px pane the chip keeps room and the badge yields', (
    tester,
  ) async {
    await _pumpAt(tester, 236);
    expect(find.byType(AppBadge), findsNothing);
    expect(tester.takeException(), isNull);
    final chip = tester.getRect(find.byType(MemberVoiceChip));
    expect(chip.width, greaterThan(AppSizes.icon12 + 40));
    expect(
      tester.getRect(find.byType(AppListRow)).right,
      greaterThan(chip.right),
    );
  });

  testWidgets('a wide row keeps both the badge and the chip', (tester) async {
    await _pumpAt(tester, 390);
    expect(find.byType(AppBadge), findsOneWidget);
    expect(find.byType(MemberVoiceChip), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a member in a call shows the channel name on their row', (
    tester,
  ) async {
    await _pump(tester, inChannel: voiceChannel('v1', 'lounge'));
    expect(find.byType(MemberVoiceChip), findsOneWidget);
    expect(find.text('lounge'), findsOneWidget);
    expect(find.byIcon(AppIcons.voice), findsOneWidget);
  });

  testWidgets('a member in no visible call shows no chip', (tester) async {
    await _pump(tester);
    expect(find.byIcon(AppIcons.voice), findsNothing);
    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('tapping the chip jumps to that channel', (tester) async {
    await _pump(tester, inChannel: voiceChannel('v1', 'lounge'));
    await tester.tap(find.text('lounge'));
    await tester.pumpAndSettle();
    expect(find.text('opened v1'), findsOneWidget);
  });

  testWidgets('the profile card placement shows it and reports the jump', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      inChannel: voiceChannel('v1', 'lounge'),
      body: MemberProfileVoice(userId: 'ada', onOpened: () => opened++),
    );
    await tester.tap(find.text('lounge'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('opened v1'), findsOneWidget);
  });

  testWidgets('the card placement is empty outside a call', (tester) async {
    await _pump(tester, body: const MemberProfileVoice(userId: 'ada'));
    expect(find.byType(MemberVoiceChip), findsNothing);
  });
}
