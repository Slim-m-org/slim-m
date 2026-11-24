// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A launch whose widget is gone before the server answers still lands: the
/// posted message is applied locally and the launch reports success.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/app_launcher_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _app = api.App(
  moduleId: 'mod-1',
  command: 'whiteboard',
  name: 'Whiteboard',
  description: 'Draw together',
);

void main() {
  testWidgets('a launch answered after its widget left is still applied', (
    tester,
  ) async {
    final db = data.SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = data.MessageStore(db);
    final hold = Completer<void>();
    var posted = false;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'self',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
        storeProvider.overrideWith((ref) async => store),
        mockApiOverride((request) async {
          posted = true;
          await hold.future;
          return http.Response(
            jsonEncode({
              'id': 'launch-1',
              'channel_id': 'c1',
              'author_id': 'self',
              'author_display_name': 'Me',
              'seq': 1,
              'content': '',
              'created_at': 1000,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (context, on, _) => on
                ? Consumer(
                    builder: (context, ref, _) {
                      widgetRef = ref;
                      return const SizedBox();
                    },
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    final errors = <String>[];

    late Future<bool> launched;
    await tester.runAsync(() async {
      launched = launchApp(
        ref: widgetRef,
        id: 'launch-1',
        channelId: 'c1',
        app: _app,
        onError: errors.add,
      );
      while (!posted) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    shown.value = false;
    await tester.pump();
    hold.complete();
    final ok = await tester.runAsync(() => launched);

    expect(ok, isTrue, reason: errors.join());
    expect(
      await tester.runAsync(() => store.hasMessage('c1', 'launch-1')),
      isTrue,
    );
  });
}
