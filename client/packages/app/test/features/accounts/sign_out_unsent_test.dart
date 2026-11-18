// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing out wipes the local store, so Sign out asks first while a message
/// has not been sent, and says how many would go.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _NoopPush extends PushController {
  _NoopPush(super.ref);

  @override
  Future<void> register() async {}
}

class _Unsent extends MessageStore {
  _Unsent(super.db, this.count);

  final int count;

  @override
  Future<int> unsentCount() async => count;
}

Future<({ProviderContainer container, List<String> logouts})> _pump(
  WidgetTester tester, {
  required int unsent,
}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final logouts = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      pushControllerProvider.overrideWith(_NoopPush.new),
      storeProvider.overrideWith((ref) async => _Unsent(db, unsent)),
      mockApiOverride((request) async {
        if (request.url.path == '/auth/logout') logouts.add(request.url.path);
        return http.Response(
          '',
          request.url.path == '/auth/logout' ? 204 : 404,
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: SignOutRow()),
      ),
    ),
  );
  return (container: container, logouts: logouts);
}

void main() {
  testWidgets('with unsent messages, Sign out says so and Cancel keeps you '
      'signed in', (tester) async {
    final h = await _pump(tester, unsent: 2);

    await tester.tap(find.text('Sign out'));
    await pumpFrames(tester, frames: 20);

    expect(
      find.text('2 messages have not been sent yet. Signing out deletes them.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester, frames: 20);

    expect(h.logouts, isEmpty);
    expect(h.container.read(sessionProvider).tokens, isNotNull);
  });

  testWidgets('confirming signs out', (tester) async {
    final h = await _pump(tester, unsent: 1);

    await tester.tap(find.text('Sign out'));
    await pumpFrames(tester, frames: 20);
    expect(
      find.text('1 message has not been sent yet. Signing out deletes it.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(AppButton, 'Sign out'));
    await pumpFrames(tester, frames: 20);

    expect(h.logouts, ['/auth/logout']);
  });

  testWidgets('with nothing unsent, Sign out signs out at once', (
    tester,
  ) async {
    final h = await _pump(tester, unsent: 0);

    await tester.tap(find.text('Sign out'));
    await pumpFrames(tester, frames: 20);

    expect(find.text('Sign out?'), findsNothing);
    expect(h.logouts, ['/auth/logout']);
  });
}
