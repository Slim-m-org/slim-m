// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The deep-link/reload half of UX1: a cold-opened `/thread/:id` on a wide
/// viewport resolves its parent channel, sets `openThreadProvider`, and lands
/// on that channel - so a reload, a notification tap or a pasted link reaches
/// the same docked pane an in-app "open thread" does, rather than the modal
/// that used to cover the transcript. `home_shell_test` covers the docked
/// presentation itself; this covers the route that gets a cold open there.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _server = 'https://chat.example';

({ProviderContainer container, SlimmDatabase db}) _setup() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final probeClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'push_enabled': true,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      databaseProvider.overrideWith((ref) => db),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (_) async => throw StateError('no network in this test'),
          ),
        );
        ref.onDispose(api.close);
        return api;
      }),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: probeClient),
      ),
      threadParentProvider('c-thread').overrideWith(
        (ref) async => const ThreadParent(
          parentChannelId: 'c1',
          parentChannelName: 'general',
          parentMessageId: 'm1',
        ),
      ),
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

void main() {
  testWidgets(
    'a cold /thread/:id on a wide viewport docks beside its parent, landing '
    'on the parent channel with the thread open',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (:container, :db) = _setup();
      container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));
      container.read(sessionProvider).set(_tokens);

      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(1400, 900),
              disableAnimations: true,
            ),
            child: MaterialApp.router(
              theme: buildTheme(Brightness.light, AppTokens.light),
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.pump();

      router.go('/thread/c-thread');
      // Resolve the parent, run the post-frame redirect, then land.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        router.state.matchedLocation,
        Routes.channel('c1'),
        reason: 'docked: the cold thread redirected onto its parent channel',
      );
      expect(
        container.read(openThreadProvider),
        'c-thread',
        reason: 'with the thread itself open in the docked pane',
      );

      await _teardown(tester, container, db);
    },
  );

  testWidgets(
    'the docked thread pane draws its left edge, not under the screen',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final (:container, :db) = _setup();
      container.read(chosenServerProvider.notifier).restore(Uri.parse(_server));
      container.read(sessionProvider).set(_tokens);

      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(1400, 900),
              disableAnimations: true,
            ),
            child: MaterialApp.router(
              theme: buildTheme(Brightness.light, AppTokens.light),
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.pump();
      router.go('/thread/c-thread');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final edge = find
          .ancestor(
            of: find.byType(ThreadScreen),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).border != null,
            ),
          )
          .first;
      final border =
          (tester.widget<Container>(edge).decoration! as BoxDecoration).border!;
      expect((border as Border).left.color, AppTokens.light.borderStrong);
      expect(
        tester.getTopLeft(find.byType(ThreadScreen)).dx -
            tester.getTopLeft(edge).dx,
        border.dimensions.horizontal,
        reason: 'an opaque screen must sit inside the edge, not cover it',
      );

      await _teardown(tester, container, db);
    },
  );
}
