// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the sign-in flow's interaction with sync: SyncController is
/// session-driven (see its class doc) and reacts to a fresh sign-in on its
/// own, so nothing on this screen may also start it explicitly, or two
/// competing sockets open and one kicks the other offline.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

void main() {
  setUpAll(mockAppVersion);

  testWidgets(
    'a successful sign-in starts sync exactly once, not twice racing to '
    'open the socket',
    (tester) async {
      var listChannelsCalls = 0;
      final httpClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/auth/login') {
          return http.Response(
            jsonEncode(_tokens.toJson()),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path == '/channels') {
          listChannelsCalls++;
          return http.Response(
            '[]',
            200,
            headers: const {'content-type': 'application/json'},
          );
        }

        /// Cut sync's start() short right after the channel refresh this test
        /// counts: a 404 here is caught by start()'s own try/catch (offline,
        /// retry scheduled) well before any real socket is ever attempted.
        if (request.method == 'POST' && request.url.path == '/auth/ws-ticket') {
          return http.Response('{"error":"not found"}', 404);
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: httpClient,
            );
            ref.onDispose(api.close);
            return api;
          }),
          storeProvider.overrideWith((ref) async {
            final db = SlimmDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return MessageStore(db);
          }),
        ],
      );

      /// Disposed explicitly at the end of the test body, not via addTearDown:
      /// a failed sync attempt schedules a real retry Timer, and
      /// flutter_test's pending-timer check runs before addTearDown callbacks
      /// do, so relying on addTearDown here would fail the test on that check
      /// rather than on what this test is actually about.

      /// Mirrors main(): SyncController is constructed, and its session
      /// listener subscribed, before any navigation can reach the sign-in
      /// screen - exactly like the real app, and exactly what makes the
      /// listener (not an explicit call from this screen) the one thing that
      /// starts sync.
      container.read(syncControllerProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const SignInScreen(),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(
        listChannelsCalls,
        1,
        reason:
            'two start() calls each refresh channels once; a single, '
            'session-driven start is the only thing allowed to run',
      );

      container.dispose();
    },
  );

  group('push reachability', () {
    /// Pumps the screen with /version answering [versionBody] and returns
    /// the finder for the no-push notice.
    Future<Finder> pumpWithVersion(
      WidgetTester tester,
      Map<String, Object?> versionBody,
    ) async {
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode(versionBody),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          probeApiProvider.overrideWithValue(
            (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      return find.textContaining('cannot send push notifications');
    }

    testWidgets('a server that reports no push says so before sign-in', (
      tester,
    ) async {
      final notice = await pumpWithVersion(tester, {
        'name': 'slim-m',
        'version': '0.8.0',
        'protocol': 1,
        'push_enabled': false,
      });
      expect(notice, findsOneWidget);
    });

    testWidgets('a server with push shows no notice', (tester) async {
      final notice = await pumpWithVersion(tester, {
        'name': 'slim-m',
        'version': '0.8.0',
        'protocol': 1,
        'push_enabled': true,
      });
      expect(notice, findsNothing);
    });

    testWidgets('a server too old to say is not accused of having no push', (
      tester,
    ) async {
      final notice = await pumpWithVersion(tester, {
        'name': 'slim-m',
        'version': '0.6.0',
        'protocol': 1,
      });
      expect(notice, findsNothing);
    });

    testWidgets('editing the field re-probes, and a slow failure from the old '
        'address cannot wipe the notice the new one earned', (tester) async {
      /// The prefilled server hangs until told to fail; the typed one
      /// answers no-push immediately. The stale failure arriving after the
      /// fresh answer is exactly the interleaving the guard exists for.
      final oldServerGate = Completer<void>();
      final httpClient = MockClient((request) async {
        if (request.url.host == 'old.example') {
          await oldServerGate.future;
          throw http.ClientException('connection timed out');
        }
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '0.8.0',
            'protocol': 1,
            'push_enabled': false,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          serverUrlProvider.overrideWith(
            (ref) => Uri.parse('http://old.example'),
          ),
          probeApiProvider.overrideWithValue(
            (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pump();

      final notice = find.textContaining('cannot send push notifications');
      expect(notice, findsNothing);

      await tester.enterText(
        find.byType(TextField).first,
        'http://new.example',
      );
      // Past the debounce, then let the probe's response apply.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(
        notice,
        findsOneWidget,
        reason: 'editing the field must probe the new address',
      );

      // Now the old address's probe finally fails. The notice belongs to
      // the current address and must survive the stale failure.
      oldServerGate.complete();
      await tester.pump();
      await tester.pump();
      expect(
        notice,
        findsOneWidget,
        reason:
            'a stale failure for a previous address must not '
            'relabel the current one as unknown',
      );
    });
  });

  testWidgets('a screen popped before its deferred provider write runs is left '
      'stale, never thrown into', (tester) async {
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    container.read(assumeNewAccountProvider.notifier).state = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const SignInScreen(),
        ),
      ),
    );

    // Unmount before the real zero-duration Timer `Future(() {...})` scheduled fires - a bare `pumpWidget` never elapses time, so nothing has fired it yet.
    await tester.pumpWidget(const SizedBox.shrink());
    // Now let it fire.
    await tester.pump(const Duration(milliseconds: 1));

    expect(tester.takeException(), isNull);
    expect(
      container.read(assumeNewAccountProvider),
      isTrue,
      reason: 'a disposed screen must not write into the provider',
    );
  });

  testWidgets(
    'the server field starts from the onboarding choice, not a hardcoded '
    'address',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          serverUrlProvider.overrideWith(
            (ref) => Uri.parse('https://chat.example'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'https://chat.example');
    },
  );
}
