// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner's report: trapped in the compact voice call UI on an iPhone -
/// "no way to swipe out or leave without hanging up", and a second visit
/// after a leave/rejoin cycle lost the top bar entirely.
///
/// Drives the real `HomeShell`/`ConversationPane`/`VoiceScreen` tree (the
/// same shape `voice_channel_row_rejoin_test.dart` and
/// `home_shell_voice_strip_test.dart` already use) through every step of
/// that sequence - fresh arrival, connected, hang up, the rejoin screen,
/// rejoin, and leaving the screen (not the call) to navigate back - and
/// asserts a back affordance survives every one of them. It does for a real
/// voice channel already; what this also pins down is the DM call bar,
/// which used to have no way back to the channel rail at all short of
/// closing the call pane first.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_controller_harness.dart';

const _voiceChannelId = 'c-voice';
const _dmChannelId = 'c-dm';

final _channels = [
  const api.Channel(
    id: _voiceChannelId,
    name: 'General voice',
    kind: 'voice',
    createdAt: 0,
  ),
  const api.Channel(id: _dmChannelId, name: 'Alice', kind: 'dm', createdAt: 0),
];

/// Answers the voice endpoints a real join needs, plus the quiet defaults
/// `home_shell_harness.quietClient` already gives every other fetch.
MockClient _client() => MockClient((request) async {
  final path = request.url.path;
  if (path.endsWith('/voice/heartbeat')) return http.Response('', 204);
  if (path.endsWith('/voice/token')) {
    return http.Response(
      jsonEncode({
        'url': 'wss://sfu.example.com',
        'room': _voiceChannelId,
        'token': 'jwt',
        'expires_at': 0,
        'can_publish': true,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  final Object body = switch (path) {
    '/me' => {
      'id': 'bob',
      'username': 'bob',
      'display_name': 'Bob',
      'created_at': 0,
      'permissions': 0,
    },
    _ when path.endsWith('/voice/roster') => const {'participants': <Object>[]},
    _ => const <Object>[],
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
});

typedef _Fixture = ({
  ProviderContainer container,
  SlimmDatabase db,
  GoRouter router,
  VoiceController controller,
  FakeSession session,
});

Future<_Fixture> _pump(WidgetTester tester, String location) async {
  final session = FakeSession();
  final fixture = setup(
    signedIn: true,
    httpClient: _client(),
    extraOverrides: [
      voiceRosterProvider(
        _voiceChannelId,
      ).overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await store.upsertChannels(_channels);
  final controller = fixture.container.read(voiceControllerProvider.notifier);
  final router = testRouter(location);

  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    container: fixture.container,
    db: fixture.db,
    router: router,
    controller: controller,
    session: session,
  );
}

void main() {
  testWidgets(
    'a real voice channel keeps its back affordance through join, hang up, '
    'a revisit to the rejoin screen, and rejoining',
    (tester) async {
      final f = await _pump(tester, '/channels/$_voiceChannelId');

      // Auto-join fires on arrival; drive the fake session to "connected".
      await tester.pumpAndSettle(const Duration(seconds: 1));
      f.session.emitState(VoiceSessionState.connected);
      await tester.pumpAndSettle();
      expect(
        find.byType(CompactChannelAppBar),
        findsOneWidget,
        reason: 'connected and alone must still show the compact back button',
      );

      await f.controller.leave();
      await tester.pumpAndSettle();
      expect(
        f.router.routerDelegate.currentConfiguration.uri.toString(),
        '/channels',
        reason: 'a phone hang-up leaves the call screen (voice_hangup_return)',
      );

      f.router.go('/channels/$_voiceChannelId');
      await tester.pumpAndSettle();
      expect(
        find.byType(CompactChannelAppBar),
        findsOneWidget,
        reason: 'the rejoin screen must keep the same back button too',
      );

      await f.controller.join(_voiceChannelId);
      f.session.emitState(VoiceSessionState.connected);
      await tester.pumpAndSettle();
      expect(find.byType(CompactChannelAppBar), findsOneWidget);

      await teardown(tester, f.container, f.db);
    },
  );

  testWidgets(
    'leaving the call screen through the back button never hangs up the '
    'call, and it is still there on return',
    (tester) async {
      final f = await _pump(tester, '/channels/$_voiceChannelId');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      f.session.emitState(VoiceSessionState.connected);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(AppIcons.back));
      await tester.pumpAndSettle();
      expect(
        f.controller.state.state,
        VoiceSessionState.connected,
        reason: 'leaving the screen is not the same as hanging up',
      );

      f.router.go('/channels/$_voiceChannelId');
      await tester.pumpAndSettle();
      expect(
        find.byType(CompactChannelAppBar),
        findsOneWidget,
        reason: 'still connected, revisited: the back button must survive too',
      );

      await teardown(tester, f.container, f.db);
    },
  );

  testWidgets('a DM call keeps a way back to the channel list, not just a way to '
      'close the call pane', (tester) async {
    final f = await _pump(tester, '/channels/$_dmChannelId');
    f.container.read(dmCallOpenProvider.notifier).state = _dmChannelId;
    await tester.pumpAndSettle();

    // The DM call bar replaces the compact app bar, but must carry an equivalent leading back button.
    expect(find.byType(CompactChannelAppBar), findsNothing);
    expect(find.bySemanticsLabel('Back to messages'), findsOneWidget);
    final backButtons = find.widgetWithIcon(IconButton, AppIcons.back);
    expect(
      backButtons,
      findsOneWidget,
      reason:
          'a DM call must reach the channel list without closing the '
          'call pane first',
    );

    await tester.tap(backButtons);
    await tester.pumpAndSettle();
    expect(
      f.router.routerDelegate.currentConfiguration.uri.toString(),
      '/channels',
    );

    await teardown(tester, f.container, f.db);
  });
}
