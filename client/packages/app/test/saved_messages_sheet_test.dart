// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The saved messages sheet's actions: removing a save, a removal that fails,
/// and tapping a row to jump to its message.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/saved_messages_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {
    state = SyncStatus.live;
  }
}

const _saved = {
  'id': 'm1',
  'channel_id': 'c2',
  'author_id': 'other',
  'author_display_name': 'Other',
  'seq': 1,
  'content': 'kept for later',
  'created_at': 0,
  'edited_at': null,
  'saved_at': 0,
};

class _Wire {
  _Wire({this.deleteStatus = 204});

  final int deleteStatus;
  var saved = <Map<String, Object?>>[_saved];
  final requests = <String>[];

  Future<http.Response> handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}');
    if (request.method == 'DELETE') {
      if (deleteStatus != 204) {
        return http.Response(jsonEncode({'error': 'boom'}), deleteStatus);
      }
      saved = [];
      return http.Response('', 204);
    }
    final body = request.url.path == '/users' ? <Object>[] : saved;
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<ProviderContainer> _open(WidgetTester tester, _Wire wire) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => MessageStore(db)),
      syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
      channelByIdProvider('c2').overrideWith((ref) => Stream.value(null)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(wire.handle),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSavedMessagesSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) =>
            Text('channel ${state.pathParameters['channelId']}'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('removing a save unsaves it and refreshes the list', (
    tester,
  ) async {
    final wire = _Wire();
    await _open(tester, wire);
    expect(find.text('kept for later'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.removeFromList));
    await tester.pumpAndSettle();

    expect(wire.requests, contains('DELETE /messages/m1/save'));
    expect(find.text('kept for later'), findsNothing);
    expect(find.textContaining('Nothing saved yet'), findsOneWidget);
  });

  testWidgets('a failed removal keeps the row and says so inline', (
    tester,
  ) async {
    final wire = _Wire(deleteStatus: 500);
    await _open(tester, wire);

    await tester.tap(find.byIcon(AppIcons.removeFromList));
    await tester.pumpAndSettle();

    expect(find.text('kept for later'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
  });

  testWidgets('tapping a saved message closes the sheet and jumps to it', (
    tester,
  ) async {
    final container = await _open(tester, _Wire());

    await tester.tap(find.text('kept for later'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing saved yet'), findsNothing);
    expect(find.text('kept for later'), findsNothing);
    expect(find.text('channel c2'), findsOneWidget);
    expect(container.read(messageJumpProvider), isNot(isA<MessageJumpIdle>()));
  });
}
