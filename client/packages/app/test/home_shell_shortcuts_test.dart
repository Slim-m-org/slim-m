// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `platform`'s shortcut table advertised six actions; only two
/// (`quickSwitch`, `escape`) were ever bound to anything in the shell, so
/// the other four did nothing no matter what key a user pressed. This
/// drives the real shell and asserts the remaining four now do.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_extras.dart'
    show ComposerField;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Every read answers empty except `/me`, so the shell's own permission and
/// membership checks resolve instead of sitting in an error state.
MockClient _quietClient() => MockClient((request) async {
  final Object body = request.url.path == '/me'
      ? {
          'id': 'bob',
          'username': 'bob',
          'display_name': 'Bob',
          'created_at': 0,
          'permissions': 0,
        }
      : const <Object>[];
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
});

({ProviderContainer container, SlimmDatabase db}) _setup() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _quietClient(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith((ref) => db),
    ],
  );
  return (container: container, db: db);
}

Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

/// The channel route shows the channel id, so a shortcut that changes
/// selection is visible without depending on `ChannelHeader` or the rail,
/// both of which also render the channel's name.
GoRouter _idRouter(String location) => GoRouter(
  initialLocation: location,
  routes: [
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: '/channels',
          builder: (context, state) => const Center(child: Text('no-channel')),
          routes: [
            GoRoute(
              path: ':channelId',
              builder: (context, state) => Center(
                child: Text('channel:${state.pathParameters['channelId']}'),
              ),
            ),
          ],
        ),
        GoRoute(
          path: Routes.personalSettings,
          builder: (context, state) =>
              const Scaffold(body: Text('personal-settings-screen')),
        ),
      ],
    ),
  ],
);

/// The real conversation pane, so a real [Composer] and its focus node are
/// on screen to check the focus shortcut against.
GoRouter _conversationRouter(String location) => GoRouter(
  initialLocation: location,
  routes: [
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: '/channels',
          builder: (context, state) => const Center(child: Text('no-channel')),
          routes: [
            GoRoute(
              path: ':channelId',
              builder: (context, state) => ConversationPane(
                channelId: state.pathParameters['channelId']!,
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Gives `_cycleChannel`'s real (native) sqlite `.first` read a chance to
/// resolve. Plain, bounded pumps, not `runAsync`: wrapping this in
/// `runAsync` deadlocked reliably against this particular shell tree.
Future<void> _settleCycle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('Ctrl+comma opens settings', (tester) async {
    final setup = _setup();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    final router = _idRouter('/channels/c1');
    await _pump(tester, setup.container, router);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('personal-settings-screen'), findsOneWidget);
    await _teardown(tester, setup.container, setup.db);
  });

  /// Three channels, deliberately: with only two, wrapping next and wrapping
  /// previous both land on the same one, so a next handler bound to previous
  /// (or the reverse) would still pass. A third channel gives each direction
  /// its own answer at every step.
  testWidgets('Ctrl+Tab moves to the next channel, wrapping at the end', (
    tester,
  ) async {
    final setup = _setup();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
      api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 1),
      api.Channel(id: 'c3', name: 'off-topic', kind: 'text', createdAt: 2),
    ]);
    final router = _idRouter('/channels/c1');
    await _pump(tester, setup.container, router);

    Future<void> next() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settleCycle(tester);
    }

    await next();
    expect(find.text('channel:c2'), findsOneWidget);

    await next();
    expect(find.text('channel:c3'), findsOneWidget);

    // Wraps: one more next from the last channel returns to the first.
    await next();
    expect(find.text('channel:c1'), findsOneWidget);

    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('Ctrl+Shift+Tab moves to the previous channel, wrapping', (
    tester,
  ) async {
    final setup = _setup();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
      api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 1),
      api.Channel(id: 'c3', name: 'off-topic', kind: 'text', createdAt: 2),
    ]);
    final router = _idRouter('/channels/c1');
    await _pump(tester, setup.container, router);

    Future<void> previous() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settleCycle(tester);
    }

    await previous();
    expect(
      find.text('channel:c3'),
      findsOneWidget,
      reason: 'from the first channel, previous must wrap to the last',
    );

    await previous();
    expect(find.text('channel:c2'), findsOneWidget);

    await previous();
    expect(find.text('channel:c1'), findsOneWidget);

    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('Ctrl+L focuses the open channel\'s composer', (tester) async {
    final setup = _setup();
    await MessageStore(setup.db).upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    final router = _conversationRouter('/channels/c1');
    await _pump(tester, setup.container, router);

    final field = tester.widget<ComposerField>(find.byType(ComposerField));
    expect(
      field.focusNode.hasFocus,
      isFalse,
      reason: 'the shell itself holds focus on launch, not the composer',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(field.focusNode.hasFocus, isTrue);
    await _teardown(tester, setup.container, setup.db);
  });
}
