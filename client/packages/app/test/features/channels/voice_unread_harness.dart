// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real home shell holding one voice channel with something unread in its chat,
/// shared by the tests that read that chat without joining the call.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/first_run/providers/first_run_rules.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';
import '../../support/async_wait.dart';
import '../voice/voice_controller_harness.dart' show FakeSession;

const voiceId = 'c-voice';
const voiceSpace = 'https://space.test';

class VoiceTestServer extends ChosenServer {
  @override
  Uri? build() => Uri.parse(voiceSpace);
}

/// What puts the voice channel in the list.
enum VoiceWaiting {
  /// A mention whose message is held, the default voice rule's one way in.
  heldMention,

  /// A plain message, listed because the reader set the channel to all messages.
  everyMessage,

  /// A mention known from the read state whose message was never fetched.
  mentionNotHeld,
}

typedef VoiceShell = ({
  ProviderContainer container,
  SlimmDatabase db,
  GoRouter router,
  List<String> tokenRequests,
});

/// [testRouter] with the real home at `/channels`, where the card lives.
GoRouter voiceTestRouter() => GoRouter(
  initialLocation: Routes.channels,
  routes: [
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: Routes.channels,
          builder: (context, state) => const NoChannelSelected(),
          routes: [
            GoRoute(
              path: ':channelId',
              builder: (context, state) => ConversationPane(
                channelId: state.pathParameters['channelId']!,
                openChat: Routes.opensChat(state.uri),
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);

Future<VoiceShell> pumpVoiceShell(
  WidgetTester tester,
  double width,
  VoiceWaiting why,
) async {
  // A member who finished setup, so the home shows what is waiting rather than the welcome.
  SharedPreferences.setMockInitialValues({
    firstRunDoneKey(voiceSpace, tokens.userId): true,
  });
  final tokenRequests = <String>[];
  final quiet = quietClient();
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/voice/token')) tokenRequests.add(path);
    if (path == '/notification-preferences/channels' &&
        why == VoiceWaiting.everyMessage) {
      return http.Response(
        jsonEncode([
          {'channel_id': voiceId, 'preference': 'everything'},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response.fromStream(
      await quiet.send(http.Request(request.method, request.url)),
    );
  });
  final fixture = setup(
    signedIn: true,
    httpClient: client,
    extraOverrides: [
      chosenServerProvider.overrideWith(VoiceTestServer.new),
      voiceRosterProvider(voiceId).overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await tester.runAsync(() async {
    await store.upsertChannels(const [
      api.Channel(
        id: voiceId,
        name: 'movie-room',
        kind: 'voice',
        createdAt: 0,
        position: 0,
      ),
    ]);
    if (why == VoiceWaiting.mentionNotHeld) {
      await store.advanceMentionCursor(voiceId, 5);
      return;
    }
    await store.applyMessages([
      api.Message(
        id: 'm-1',
        channelId: voiceId,
        authorId: 'alice',
        authorDisplayName: 'Alice',
        seq: 1,
        content: 'hey @bob',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        editedAt: null,
        mentionsMe: why == VoiceWaiting.heldMention,
      ),
    ]);
  });
  final router = voiceTestRouter();
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

/// Pumps until [finder] shows, giving drift's queries real time between frames.
Future<Finder> shownWhenReady(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
  return finder;
}

/// Opens the inbox from the space menu.
Future<void> openInbox(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Space menu'));
  await pumpFrames(tester);
  await tester.tap(find.text('Inbox'));
  await pumpFrames(tester);
}

/// The chat is open on its own route and no call was joined or asked for.
Future<void> expectReadsWithoutJoining(
  WidgetTester tester,
  VoiceShell s,
) async {
  await pumpFrames(tester, frames: 20);
  expect(
    s.router.routerDelegate.currentConfiguration.uri.toString(),
    Routes.channel(voiceId, openChat: true),
  );
  expect(s.tokenRequests, isEmpty, reason: 'reading never joins');
  expect(s.container.read(voiceFlagsProvider).channelId, isNull);
}

/// [expectReadsWithoutJoining], then the shell torn down.
Future<void> expectReadingWithoutJoining(
  WidgetTester tester,
  VoiceShell s,
) async {
  await expectReadsWithoutJoining(tester, s);
  await teardown(tester, s.container, s.db);
}
