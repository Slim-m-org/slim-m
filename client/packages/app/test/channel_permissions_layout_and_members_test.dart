// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid inside a scrolling settings pane: packed against the
/// left edge, one vertical scroller, and the channel's member list refreshed
/// by a save that grants view and by the live overwrite event.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid_rows.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

final _channel = Channel(
  id: 'c-secret',
  name: 'secret',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

api.UserProfile _member(String id, String name) => api.UserProfile(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  createdAt: 0,
);

Map<String, dynamic> _json(api.UserProfile m) => {
  'id': m.id,
  'username': m.username,
  'display_name': m.displayName,
  'created_at': 0,
};

class _Server {
  final granted = <String>{};
  int memberFetches = 0;

  Future<http.Response> handle(http.Request request) async {
    const headers = {'content-type': 'application/json'};
    if (request.url.path == '/members') {
      memberFetches++;
      return http.Response(
        jsonEncode([
          _json(_member('self', 'Nick')),
          for (final id in granted) _json(_member(id, id)),
        ]),
        200,
        headers: headers,
      );
    }
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final o in body['overwrites'] as List<dynamic>) {
        final m = o as Map<String, dynamic>;
        if ((m['allow'] as int) & Perm.viewChannel != 0) {
          granted.add(m['id'] as String);
        }
      }
    }
    return http.Response(
      jsonEncode({
        'overwrites': [
          for (final id in granted)
            {'kind': 'member', 'id': id, 'allow': Perm.viewChannel, 'deny': 0},
        ],
      }),
      200,
      headers: headers,
    );
  }
}

ProviderContainer _container(
  _Server server, {
  Stream<api.ServerEvent> events = const Stream.empty(),
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith(
        (ref) async => [
          _member('m-nadia', 'm-nadia'),
          _member('m-omar', 'Omar'),
        ],
      ),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.viewChannel),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(server.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _pane(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ChannelPermissionsGrid(channel: _channel),
      ),
    ),
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final (name, size, labelWidth) in [
    ('desktop', const Size(1000, 900), GridMetrics.wideLabelWidth),
    ('phone', const Size(390, 844), GridMetrics.compactLabelWidth),
  ]) {
    testWidgets('$name: the first column sits right after the label column', (
      tester,
    ) async {
      _size(tester, size);
      await tester.pumpWidget(_pane(_container(_Server())));
      await tester.pumpAndSettle();

      final cell = find.byKey(
        ValueKey('cell:role:role-everyone:${Perm.viewChannel}'),
      );
      expect(tester.getTopLeft(cell).dx, labelWidth);
      expect(
        tester.getTopLeft(find.text('View channels').first).dx,
        lessThan(AppSpacing.s16 + 1),
        reason: 'permission names start at the left edge, not centred',
      );
    });
  }

  testWidgets('the grid adds no vertical scroller of its own', (tester) async {
    _size(tester, const Size(1000, 900));
    await tester.pumpWidget(_pane(_container(_Server())));
    await tester.pumpAndSettle();

    final nested = find.descendant(
      of: find.byType(ChannelPermissionsGrid),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axis == Axis.vertical,
      ),
    );
    expect(nested, findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      findsOneWidget,
      reason: 'the settings pane is the only vertical scroller',
    );
  });

  testWidgets('saving a view grant refreshes the channel member list', (
    tester,
  ) async {
    _size(tester, const Size(1000, 900));
    final server = _Server();
    final container = _container(server);
    final sub = container.listen(
      channelMembersProvider(_channel.id),
      (_, __) {},
    );
    await tester.runAsync(
      () => container.read(channelMembersProvider(_channel.id).future),
    );
    expect(sub.read().requireValue.map((m) => m.id), ['self']);

    await tester.pumpWidget(_pane(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add role or member'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a member'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('m-nadia'));
    await tester.pumpAndSettle();
    final cell = find.byKey(
      ValueKey('cell:member:m-nadia:${Perm.viewChannel}'),
    );
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save changes'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => container.read(channelMembersProvider(_channel.id).future),
    );

    expect(sub.read().requireValue.map((m) => m.id), contains('m-nadia'));
    sub.close();
  });

  test('a live OverwriteChanged refreshes the channel member list', () async {
    final server = _Server();
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = _container(server, events: events.stream);
    final watcher = container.listen(roleChangeWatcherProvider, (_, __) {});
    final sub = container.listen(
      channelMembersProvider(_channel.id),
      (_, __) {},
    );
    await container.read(channelMembersProvider(_channel.id).future);
    server.granted.add('m-nadia');

    events.add(api.OverwriteChanged(channelId: _channel.id));
    await Future<void>.delayed(Duration.zero);
    final members = await container.read(
      channelMembersProvider(_channel.id).future,
    );

    expect(members.map((m) => m.id), contains('m-nadia'));
    watcher.close();
    sub.close();
  });
}
