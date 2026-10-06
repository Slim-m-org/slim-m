// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the channel while a bulk delete is in flight must not throw or strand the selection.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/message_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/channel_message_actions.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'a bulk delete finishing after the screen is gone still clears the selection',
    (tester) async {
      final gate = Completer<void>();
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          storeProvider.overrideWith((ref) async => MessageStore(db)),
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                await gate.future;
                return http.Response('', 204);
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);
      final keepAlive = container.listen(
        messageSelectionProvider('c1'),
        (_, _) {},
      );
      addTearDown(keepAlive.close);
      container.read(messageSelectionProvider('c1').notifier).start('m1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => confirmAndDeleteSelectedMessages(
                    ref,
                    context,
                    channelId: 'c1',
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      // runAsync: drift's futures never complete under testWidgets' FakeAsync.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );

      expect(tester.takeException(), isNull);
      expect(keepAlive.read().ids, isEmpty);
    },
  );
}
