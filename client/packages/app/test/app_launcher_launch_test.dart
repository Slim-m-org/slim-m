// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Launching an app from the composer's Apps button: the request it posts, the
/// message reaching the local store and the extras cache, and a refusal
/// reaching the caller's error line with nothing applied.
///
/// `app_launcher_sheet_test.dart` only ever renders the empty list, so the
/// whole of `launchApp` could be replaced with `return false` and every test
/// in the suite stayed green.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/app_launch.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/app_launcher_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// See `blocking_test.dart`: the real one opens a websocket to a server that
/// is not here.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _app = api.App(
  moduleId: 'mod-1',
  command: 'whiteboard',
  name: 'Whiteboard',
  description: 'Draw together',
);

class _Rig {
  _Rig({required this.container, required this.store, required this.posts});

  final ProviderContainer container;
  final MessageStore store;
  final List<Map<String, dynamic>> posts;
}

/// A container whose `POST /channels/c1/messages/apps` answers [status], with
/// the posted bodies recorded and a real in-memory store behind it.
Future<_Rig> _rig(WidgetTester tester, {int status = 200}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await tester.runAsync(
    () => store.upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]),
  );
  final posts = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
      appLaunchProvider.overrideWith((ref) async => const [_app]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path != '/channels/c1/messages/apps') {
              return http.Response('', 404);
            }
            posts.add(jsonDecode(request.body) as Map<String, dynamic>);
            final id = posts.last['id'] as String;
            return http.Response(
              status == 200
                  ? jsonEncode({
                      'id': id,
                      'channel_id': 'c1',
                      'author_id': 'me',
                      'author_display_name': 'Me',
                      'seq': 1,
                      'content': '',
                      'created_at': 1000,
                    })
                  : jsonEncode({'error': 'no'}),
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  return _Rig(container: container, store: store, posts: posts);
}

Future<WidgetRef> _refOf(WidgetTester tester, ProviderContainer c) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return Scaffold(
              body: TextButton(
                onPressed: () => showAppLauncherSheet(context, ref, 'c1'),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('a launch posts the app, then applies the message locally', (
    tester,
  ) async {
    final rig = await _rig(tester);
    final ref = await _refOf(tester, rig.container);

    final ok = await tester.runAsync(
      () => launchApp(ref: ref, channelId: 'c1', app: _app),
    );

    expect(ok, isTrue);
    expect(rig.posts, hasLength(1));
    expect(rig.posts.single['module_id'], 'mod-1');
    expect(rig.posts.single['command'], 'whiteboard');
    final id = rig.posts.single['id'] as String;
    final stored = await tester.runAsync(() => rig.store.channelSnapshot('c1'));
    expect(stored!.map((m) => m.id), [id]);
    expect(rig.container.read(messageExtrasProvider), contains(id));
  });

  testWidgets('a refusal reaches onError and applies nothing', (tester) async {
    final rig = await _rig(tester, status: 403);
    final ref = await _refOf(tester, rig.container);
    final errors = <String>[];

    final ok = await tester.runAsync(
      () =>
          launchApp(ref: ref, channelId: 'c1', app: _app, onError: errors.add),
    );

    expect(ok, isFalse);
    expect(errors, [
      'Could not launch Whiteboard: you are not allowed to do that.',
    ]);
    final stored = await tester.runAsync(() => rig.store.channelSnapshot('c1'));
    expect(stored, isEmpty);
    expect(rig.container.read(messageExtrasProvider), isEmpty);
  });

  testWidgets('tapping an app row in the sheet launches that app once', (
    tester,
  ) async {
    final rig = await _rig(tester);
    await _refOf(tester, rig.container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Whiteboard'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(rig.posts, hasLength(1));
    expect(rig.posts.single['command'], 'whiteboard');
  });
}
