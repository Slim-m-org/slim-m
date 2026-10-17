// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `DevicesSection`'s "Sign out" had no `try` at all: a failure threw out of
/// an async `onPressed` with no catch anywhere above it, so nothing ever
/// reached the user, and there was no test to notice. Now each row owns its
/// own guarded failure.
library;

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/personal_account_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_blocks.dart';

/// Stands in for the real socket connection [SyncController.start] would
/// otherwise attempt: a widget test has no server at the other end, so the
/// real version hangs the test rather than failing fast. Only [startCalls]
/// is under test here; the actual catch-up and reconnect logic is covered
/// elsewhere (sync_controller_test.dart, sync_controller_race_test.dart).
class _CountingSyncController extends SyncController {
  _CountingSyncController(super.ref);

  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    state = SyncStatus.live;
  }
}

http.Response _totpStatus({bool enabled = false}) => http.Response(
  jsonEncode({
    'enabled': enabled,
    'pending': false,
    'recovery_codes_remaining': 0,
    'policy': 'optional',
    'confirmed_at': null,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _deviceJson(String id, {bool isCurrent = false}) => jsonEncode({
  'id': id,
  'name': 'A phone',
  'created_at': 0,
  'last_seen_at': 0,
  'is_current': isCurrent,
});

Future<ProviderContainer> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: DevicesSection()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signing out a device removes it from the list', (tester) async {
    var removed = false;
    final container = await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/devices') {
        return http.Response(
          removed ? '[]' : '[${_deviceJson('device-1')}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'DELETE') {
        removed = true;
        return http.Response('', 204);
      }
      return http.Response('{}', 404);
    });

    await tester.tap(find.widgetWithText(AppButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out A phone?'), findsOneWidget, reason: 'asks');
    await tester.tap(find.widgetWithText(AppButton, 'Sign out').last);
    await tester.pumpAndSettle();

    expect(find.text('No devices signed in.'), findsOneWidget);
    container.dispose();
  });

  testWidgets(
    'another device has a labelled sign-out button, this one has none',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/devices') {
          return http.Response(
            '[${_deviceJson('device-1')}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      expect(find.widgetWithText(AppButton, 'Sign out'), findsOneWidget);
    },
  );

  /// This is the exact case the finding named: a lost connection while
  /// signing out a device used to throw out of `onPressed` with nothing
  /// above it to catch it, so nothing reached the user at all.
  testWidgets(
    'a failed sign-out shows a safe sentence inline, not a thrown exception',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/devices') {
          return http.Response(
            '[${_deviceJson('device-1')}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE') {
          throw const SocketException('connection refused');
        }
        return http.Response('{}', 404);
      });

      await tester.tap(find.widgetWithText(AppButton, 'Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, 'Sign out').last);
      await tester.pumpAndSettle();

      // Still listed, and no exception escaped: `pumpAndSettle` would rethrow one.
      expect(find.text('A phone'), findsOneWidget);
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(
        find.textContaining('the server could not be reached'),
        findsOneWidget,
      );

      // Recovers rather than staying stuck: sign-out can be tried again.
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Sign out'))
            .disabled,
        isFalse,
      );
    },
  );

  /// `_BlockedRow` used to catch the failure itself and show it as a
  /// `SnackBar`, the one shape `run_guarded.dart`'s own doc comment does not
  /// offer: this row never closes before its request answers, so it always
  /// has room for `AppErrorState` the way `DevicesSection`'s row above it
  /// already does.
  testWidgets('a failed unblock shows a safe sentence inline, not a SnackBar', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/users') {
                return http.Response(
                  jsonEncode([
                    {
                      'id': 'user-blocked',
                      'username': 'kit',
                      'display_name': 'Kit',
                      'created_at': 0,
                    },
                  ]),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (request.method == 'DELETE' &&
                  request.url.path == '/blocks/user-blocked') {
                throw const SocketException('connection refused');
              }
              return http.Response('{}', 404);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(
            ref,
            const BlocksState(ids: {'user-blocked'}, settled: true),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: BlockedSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, 'Unblock'));
    await tester.pumpAndSettle();

    // Still listed: the optimistic change reverted rather than sticking.
    expect(find.text('Kit'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
    expect(
      find.textContaining('the server could not be reached'),
      findsOneWidget,
    );
  });

  group('AccountSection deletion', () {
    /// Sync and push are stopped ahead of the delete request (see the class
    /// doc: unregistering push needs a session still valid, so it cannot
    /// wait until after). A failed delete must not leave both stopped with
    /// the account still very much alive and the session still signed in.
    testWidgets(
      'a failed deletion restarts sync and re-registers push rather than '
      'leaving both stopped with no route back',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
            syncControllerProvider.overrideWith(
              (ref) => _CountingSyncController(ref),
            ),
            apiProvider.overrideWith((ref) {
              final api = SlimmApi(
                baseUrl: Uri.parse('http://localhost:8080'),
                session: ref.watch(sessionProvider),
                httpClient: MockClient((request) async {
                  if (request.method == 'DELETE' &&
                      request.url.path == '/account') {
                    return http.Response(
                      jsonEncode({'error': 'server unavailable'}),
                      500,
                      headers: {'content-type': 'application/json'},
                    );
                  }
                  if (request.method == 'DELETE' &&
                      request.url.path.contains('/push')) {
                    return http.Response('', 204);
                  }
                  if (request.url.path == '/auth/totp') return _totpStatus();
                  return http.Response('{}', 404);
                }),
              );
              ref.onDispose(api.close);
              return api;
            }),
          ],
        );
        addTearDown(container.dispose);

        final syncController =
            container.read(syncControllerProvider.notifier)
                as _CountingSyncController;
        container.read(pushControllerProvider.notifier);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light, AppTokens.light),
              home: const Scaffold(body: AccountSection()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Each controller's own construction-time work has now settled.
        expect(
          container.read(pushControllerProvider),
          PushStatus.unsupportedPlatform,
          reason: 'the test host is neither iOS nor Android',
        );
        final startsBeforeDelete = syncController.startCalls;

        await tester.tap(find.text('Delete account...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete permanently'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'correct horse');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(AppButton, 'Delete permanently'));
        await tester.pumpAndSettle();

        expect(find.byType(AppErrorState), findsOneWidget);
        expect(
          container.read(sessionProvider).isSignedIn,
          isTrue,
          reason: 'a failed delete must leave the session alone',
        );
        expect(
          syncController.startCalls,
          greaterThan(startsBeforeDelete),
          reason: 'sync must have been restarted after the failed delete',
        );
        expect(
          container.read(pushControllerProvider),
          PushStatus.unsupportedPlatform,
          reason: 'push must have been re-registered, not left notSignedIn',
        );
      },
    );
  });
}
