// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Admin screens that finish an await after they have been closed: none of
/// them may touch `ref` or `setState` on a disposed state, and a write that
/// did land still refreshes what is behind it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_app/src/screens/admin/dock_screen.dart';
import 'package:slimm_data/data.dart' show Channel, MessageStore;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

const _official = {'id': 'official', 'repo': 'nc/addons', 'official': true};
const _acme = {'id': 's1', 'repo': 'acme/mods', 'official': false};

Map<String, dynamic> _entry(String id) => {
  'id': id,
  'name': 'Module $id',
  'version': '0.1.0',
  'summary': 'Summary of $id.',
  'shadowed': false,
};

class _Upstream {
  final requests = <String>[];
  Completer<void> gate = Completer<void>();

  int count(String key) => requests.where((r) => r == key).length;

  Future<http.Response> handle(http.Request r) async {
    final key = '${r.method} ${r.url.path}';
    requests.add(key);
    switch (key) {
      case 'GET /space/dock/modules':
        return _json([_entry('official-mod')]);
      case 'GET /space/dock/installed':
        return _json(<Object>[]);
      case 'GET /space/dock/sources':
        return _json([_official, _acme]);
      case 'POST /space/dock/sources':
        await gate.future;
        return _json(_acme, 201);
      case 'DELETE /space/dock/sources/s1':
        await gate.future;
        return http.Response('', 204);
    }
    return _json(<Object>[]);
  }
}

class _FakeStore implements MessageStore {
  _FakeStore(this.channels);

  final List<Channel> channels;

  @override
  Stream<List<Channel>> watchChannels() => Stream.value(channels);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(_Upstream upstream, {MessageStore? store}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      if (store != null) storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(upstream.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _dock(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: buildTheme(Brightness.light, AppTokens.light),
    routerConfig: GoRouter(
      initialLocation: Routes.adminDock,
      routes: [
        GoRoute(
          path: Routes.adminDock,
          builder: (context, state) => const DockScreen(),
        ),
      ],
    ),
  ),
);

Widget _blank(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const SizedBox(),
  ),
);

void main() {
  testWidgets('removing a source then leaving before the answer does not '
      'throw', (tester) async {
    await _size(tester);
    final upstream = _Upstream();
    final container = _container(upstream);
    await tester.pumpWidget(_dock(container));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Remove source acme/mods'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove source').last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(upstream.requests, contains('DELETE /space/dock/sources/s1'));

    await tester.pumpWidget(_blank(container));
    upstream.gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the add-source sheet mid-submit still refreshes the '
      'catalog behind it', (tester) async {
    await _size(tester);
    final upstream = _Upstream();
    final container = _container(upstream);
    await tester.pumpWidget(_dock(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a community source'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'acme/mods');
    await tester.pump();
    await tester.tap(find.text('Add source'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(upstream.requests, contains('POST /space/dock/sources'));
    final readsBefore = upstream.count('GET /space/dock/sources');

    Navigator.of(
      tester.element(find.byType(DockScreen)),
      rootNavigator: true,
    ).pop();
    await tester.pumpAndSettle();
    upstream.gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(upstream.count('GET /space/dock/sources'), greaterThan(readsBefore));
  });

  testWidgets('picking a channel after the pane is gone does not throw', (
    tester,
  ) async {
    await _size(tester);
    final channel = Channel(
      id: 'c-general',
      name: 'general',
      kind: 'text',
      createdAt: 0,
      position: 0,
      cursor: 0,
      lastReadSeq: 0,
      mentionedSeq: 0,
      slowModeSeconds: 0,
      joinMuted: false,
      isPersonalSpace: false,
    );
    final container = _container(_Upstream(), store: _FakeStore([channel]));
    final show = ValueNotifier(true);
    addTearDown(show.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (context, on, _) =>
                  on ? const ChannelPermissionsPane() : const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a channel'));
    await tester.pumpAndSettle();
    expect(find.text('general'), findsOneWidget);

    show.value = false;
    await tester.pump();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
