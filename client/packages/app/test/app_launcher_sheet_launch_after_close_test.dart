// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking an app closes the sheet at once, while the launch request is still
/// in flight; its result must still land and must not touch the closed
/// sheet's disposed ref.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/app_launch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/app_launcher_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/sync_live_rig.dart' show rigMessage;

void main() {
  testWidgets('a launch that finishes after the sheet closed still lands', (
    tester,
  ) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    final gate = Completer<void>();
    final errors = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLaunchProvider.overrideWith(
            (ref) async => const [
              api.App(moduleId: 'm', command: 'poll', name: 'Poll'),
            ],
          ),
          myPermissionsProvider.overrideWithValue(0),
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'bob',
                accessToken: 'access',
                refreshToken: 'refresh',
                accessExpiresAt: 0,
              ),
            ),
          ),
          storeProvider.overrideWith((ref) async => store),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                await gate.future;
                return http.Response(
                  jsonEncode(rigMessage('m1', 1, 'launched')),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showAppLauncherSheet(
                  context,
                  ref,
                  'c1',
                  onError: errors.add,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Poll'));
    await tester.pumpAndSettle();
    expect(find.text('Poll'), findsNothing);

    await tester.runAsync(() async {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(errors, isEmpty);
    final landed = await tester.runAsync(() => store.hasMessage('c1', 'm1'));
    expect(landed, isTrue);
  });
}
