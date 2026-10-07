// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thread reached by an in-app route change (a pasted link writing
/// `#/thread/<id>` into a running web client) must send from its composer,
/// the same as one opened from the message menu or loaded cold. The web-only
/// half of that bug, a composer focused on an input the outgoing page owned,
/// does not exist under flutter test; the e2e threads scenario covers it.
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
import 'package:slimm_app/src/providers/threads.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/thread_screen.dart';
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

final requests = <String>[];

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
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            if (request.method == 'POST' &&
                request.url.path == '/channels/c-thread/messages') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  'id': body['id'],
                  'channel_id': 'c-thread',
                  'author_id': 'user-1',
                  'content': body['content'],
                  'seq': 1,
                  'created_at': 0,
                }),
                200,
                headers: const {'content-type': 'application/json'},
              );
            }
            throw StateError('no network for ${request.url.path}');
          }),
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
    'a thread reached by an in-app route change sends from its own composer',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      requests.clear();

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

      // Already in the app on the parent channel, as a person pasting a link would be.
      router.go(Routes.channel('c1'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // As the e2e run did: open the thread in the dock, close it, then return by the link.
      dockThread(container, 'c-thread');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      container.read(openThreadProvider.notifier).state = null;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      router.go('/thread/c-thread');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(container.read(openThreadProvider), 'c-thread');

      final threadField = find.descendant(
        of: find.byType(ThreadScreen),
        matching: find.byType(TextField),
      );
      expect(threadField, findsOneWidget);
      await tester.enterText(threadField, 'a reply from a link');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(ThreadScreen),
          matching: find.byTooltip('Send reply'),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        requests,
        contains('POST /channels/c-thread/messages'),
        reason: 'the thread composer must send; requests seen: $requests',
      );

      await _teardown(tester, container, db);
    },
  );
}
