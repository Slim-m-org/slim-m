// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Account and Blocked pane actions no other suite operates end to end: the
/// Sign out row and a successful Unblock.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/personal_account_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FixedBlocks extends BlocksController {
  _FixedBlocks(super.ref, BlocksState fixed) {
    state = fixed;
  }

  @override
  Future<void> refresh() async {}
}

class _NoopSync extends SyncController {
  _NoopSync(super.ref);

  @override
  Future<void> start() async {}
}

class _NoopPush extends PushController {
  _NoopPush(super.ref);

  @override
  Future<void> register() async {}
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget pane,
  Future<http.Response> Function(http.Request) handler,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(_NoopSync.new),
      pushControllerProvider.overrideWith(_NoopPush.new),
      storeProvider.overrideWith((ref) async => throw StateError('n/a')),
      blocksProvider.overrideWith(
        (ref) => _FixedBlocks(
          ref,
          const BlocksState(ids: {'user-blocked'}, settled: true),
        ),
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(handler),
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
        home: Scaffold(body: pane),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the Sign out row logs out and clears the session', (
    tester,
  ) async {
    var loggedOut = false;
    final container = await _pump(tester, const SignOutRow(), (request) async {
      if (request.url.path == '/auth/logout') {
        loggedOut = true;
        return http.Response('', 204);
      }
      return http.Response('', 404);
    });

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(loggedOut, isTrue);
    expect(container.read(sessionProvider).tokens, isNull);
  });

  testWidgets('Unblock deletes the block and drops the row', (tester) async {
    var deleted = false;
    await _pump(tester, const BlockedSection(), (request) async {
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
        deleted = true;
        return http.Response('', 204);
      }
      return http.Response('{}', 404);
    });
    expect(find.text('Kit'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Unblock'));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
    expect(find.text('Kit'), findsNothing);
    expect(find.text('Nobody is blocked'), findsOneWidget);
  });
}
