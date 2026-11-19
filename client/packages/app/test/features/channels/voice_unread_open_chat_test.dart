// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: "I can't clear a notification easily or read a chat on mobile/desktop of a voice chat without joining the voice channel".
/// The home's "Waiting for you" card and the inbox open a voice channel's chat without joining, as its row menu does.
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
import 'package:slimm_app/src/features/messages/widgets/inbox_sheet.dart';
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

const _voiceId = 'c-voice';
const _space = 'https://space.test';

class _Server extends ChosenServer {
  @override
  Uri? build() => Uri.parse(_space);
}

/// What puts the voice channel in the list.
enum _Waiting {
  /// A mention whose message is held, the default voice rule's one way in.
  heldMention,

  /// A plain message, listed because the reader set the channel to all messages.
  everyMessage,

  /// A mention known from the read state whose message was never fetched.
  mentionNotHeld,
}

typedef _Shell = ({
  ProviderContainer container,
  SlimmDatabase db,
  GoRouter router,
  List<String> tokenRequests,
});

/// [testRouter] with the real home at `/channels`, where the card lives.
GoRouter _router() => GoRouter(
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

Future<_Shell> _pump(WidgetTester tester, double width, _Waiting why) async {
  // A member who finished setup, so the home shows what is waiting rather than the welcome.
  SharedPreferences.setMockInitialValues({
    firstRunDoneKey(_space, tokens.userId): true,
  });
  final tokenRequests = <String>[];
  final quiet = quietClient();
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/voice/token')) tokenRequests.add(path);
    if (path == '/notification-preferences/channels' &&
        why == _Waiting.everyMessage) {
      return http.Response(
        jsonEncode([
          {'channel_id': _voiceId, 'preference': 'everything'},
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
      chosenServerProvider.overrideWith(_Server.new),
      voiceRosterProvider(_voiceId).overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await tester.runAsync(() async {
    await store.upsertChannels(const [
      api.Channel(
        id: _voiceId,
        name: 'movie-room',
        kind: 'voice',
        createdAt: 0,
        position: 0,
      ),
    ]);
    if (why == _Waiting.mentionNotHeld) {
      await store.advanceMentionCursor(_voiceId, 5);
      return;
    }
    await store.applyMessages([
      api.Message(
        id: 'm-1',
        channelId: _voiceId,
        authorId: 'alice',
        authorDisplayName: 'Alice',
        seq: 1,
        content: 'hey @bob',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        editedAt: null,
        mentionsMe: why == _Waiting.heldMention,
      ),
    ]);
  });
  final router = _router();
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
Future<Finder> _shown(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
  return finder;
}

Future<void> _openInbox(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Space menu'));
  await pumpFrames(tester);
  await tester.tap(find.text('Inbox'));
  await pumpFrames(tester);
}

Future<void> _expectReadingWithoutJoining(WidgetTester tester, _Shell s) async {
  await pumpFrames(tester, frames: 20);
  expect(
    s.router.routerDelegate.currentConfiguration.uri.toString(),
    Routes.channel(_voiceId, openChat: true),
  );
  expect(s.tokenRequests, isEmpty, reason: 'reading never joins');
  expect(s.container.read(voiceFlagsProvider).channelId, isNull);
  await teardown(tester, s.container, s.db);
}

void main() {
  testWidgets('the home card opens a voice chat without joining', (
    tester,
  ) async {
    final s = await _pump(tester, 1280, _Waiting.heldMention);
    final card = find.widgetWithText(AppCard, 'WAITING FOR YOU');
    await tester.tap(
      await _shown(
        tester,
        find.descendant(of: card, matching: find.text('#movie-room')),
      ),
    );
    await _expectReadingWithoutJoining(tester, s);
  });

  for (final (width, why) in [
    (390.0, _Waiting.everyMessage),
    (1280.0, _Waiting.everyMessage),
    (390.0, _Waiting.mentionNotHeld),
  ]) {
    testWidgets('the inbox opens a voice chat without joining, '
        '${why.name} at $width', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await _pump(tester, width, why);
      await _openInbox(tester);
      await tester.tap(
        await _shown(
          tester,
          find.descendant(
            of: find.byKey(inboxBodyBoxKey),
            matching: find.text('#movie-room'),
          ),
        ),
      );
      semantics.dispose();
      await _expectReadingWithoutJoining(tester, s);
    });
  }
}
