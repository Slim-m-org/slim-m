// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: "I can't clear a notification easily or read a chat on mobile/desktop of a voice chat without joining the voice channel".
/// A voice row's menu opens its chat without joining at every width, reading there clears the row, and a tap still joins once.
/// Out of the call its chat toggle stays mentions only, the rail's rule; only a call lights it for every message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_chat_unread_dot.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';
import '../../support/async_wait.dart';
import '../../support/menu_gestures.dart';
import '../voice/voice_controller_harness.dart' show FakeSession;

const _voiceId = 'c-voice';
const _lobbyId = 'c-lobby';

typedef _Shell = ({
  ProviderContainer container,
  SlimmDatabase db,
  GoRouter router,
  List<String> tokenRequests,
});

Future<_Shell> _pump(WidgetTester tester, double width) async {
  final tokenRequests = <String>[];
  final quiet = quietClient();
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/voice/token')) {
      tokenRequests.add(request.url.path);
    }
    return http.Response.fromStream(
      await quiet.send(http.Request(request.method, request.url)),
    );
  });
  final fixture = setup(
    signedIn: true,
    httpClient: client,
    extraOverrides: [
      for (final id in [_voiceId, _lobbyId])
        voiceRosterProvider(id).overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await tester.runAsync(() async {
    await store.upsertChannels([
      const api.Channel(
        id: _voiceId,
        name: 'movie-room',
        kind: 'voice',
        createdAt: 0,
        position: 0,
      ),
      const api.Channel(
        id: _lobbyId,
        name: 'make-a-room',
        kind: 'voice',
        createdAt: 0,
        position: 1,
        createsRooms: true,
      ),
    ]);
    await store.applyMessages([
      for (final channelId in [_voiceId, _lobbyId])
        api.Message(
          id: 'm-$channelId',
          channelId: channelId,
          authorId: 'alice',
          authorDisplayName: 'Alice',
          seq: 1,
          content: 'hey @bob',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          editedAt: null,
          mentionsMe: true,
        ),
    ]);
  });
  final router = testRouter('/channels');
  tester.view.physicalSize = Size(width, 900);
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
  await pumpFrames(tester);
  return (
    container: fixture.container,
    db: fixture.db,
    router: router,
    tokenRequests: tokenRequests,
  );
}

Future<void> _openMenu(WidgetTester tester, double width, String row) =>
    width < 600
    ? longPressMenu(tester, find.text(row))
    : rightClickMenu(tester, find.text(row));

Future<void> _say(
  WidgetTester tester,
  _Shell s,
  int seq, {
  bool mentionsMe = false,
}) async {
  final store = await s.container.read(storeProvider.future);
  await tester.runAsync(
    () => store.applyMessages([
      api.Message(
        id: 'm-$seq',
        channelId: _voiceId,
        authorId: 'alice',
        authorDisplayName: 'Alice',
        seq: seq,
        content: 'more $seq',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        editedAt: null,
        mentionsMe: mentionsMe,
      ),
    ]),
  );
  await pumpFrames(tester);
}

Future<int> _lastReadSeq(WidgetTester tester, _Shell s) async {
  final store = await s.container.read(storeProvider.future);
  final rows = (await tester.runAsync(store.allChannels))!;
  return rows.singleWhere((c) => c.id == _voiceId).lastReadSeq;
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('Open chat reads a voice channel without joining at $width', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final s = await _pump(tester, width);
      expect(await _lastReadSeq(tester, s), 0);

      await _openMenu(tester, width, 'movie-room');
      await tester.tap(find.text('Open chat'));
      await pumpFrames(tester, frames: 20);

      expect(
        s.router.routerDelegate.currentConfiguration.uri.toString(),
        '/channels/$_voiceId?chat=1',
      );
      expect(find.bySemanticsLabel(RegExp('Message composer')), findsOneWidget);
      expect(s.tokenRequests, isEmpty, reason: 'reading never joins');
      expect(s.container.read(voiceFlagsProvider).channelId, isNull);
      expect(await _lastReadSeq(tester, s), 1, reason: 'reading clears it');

      semantics.dispose();
      await teardown(tester, s.container, s.db);
    });
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('out of the call only a mention marks the toggle at $width', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final s = await _pump(tester, width);
      await _openMenu(tester, width, 'movie-room');
      await tester.tap(find.text('Open chat'));
      await pumpFrames(tester, frames: 20);
      await tester.tap(find.bySemanticsLabel('Toggle text chat'));
      await pumpFrames(tester);

      await _say(tester, s, 2);
      expect(s.container.read(voiceFlagsProvider).channelId, isNull);
      expect(find.byKey(voiceChatUnreadKey), findsNothing, reason: 'plain');

      await _say(tester, s, 3, mentionsMe: true);
      expect(find.byKey(voiceChatUnreadKey), findsOneWidget, reason: 'mention');

      semantics.dispose();
      await teardown(tester, s.container, s.db);
    });
  }

  testWidgets('tapping the row after reading its chat joins the call once', (
    tester,
  ) async {
    final s = await _pump(tester, 1280);
    await _openMenu(tester, 1280, 'movie-room');
    await tester.tap(find.text('Open chat'));
    await pumpFrames(tester, frames: 20);

    await tester.tap(find.text('movie-room').first);
    await pumpFrames(tester, frames: 20);

    expect(
      s.router.routerDelegate.currentConfiguration.uri.toString(),
      '/channels/$_voiceId',
    );
    expect(s.tokenRequests, hasLength(1));

    await teardown(tester, s.container, s.db);
  });

  testWidgets('a lobby lights nothing and offers no chat or marking', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await _pump(tester, 1280);
    expect(find.bySemanticsLabel(RegExp('movie-room, mentioned')), findsOne);
    expect(find.bySemanticsLabel(RegExp('make-a-room, ')), findsNothing);

    await _openMenu(tester, 1280, 'make-a-room');

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Open chat'), findsNothing);
    expect(find.textContaining('Mark as'), findsNothing);

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });
}
