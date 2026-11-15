// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a settings page that scrolls, the grid's column names stay at the top of
/// the view while its rows are on screen, and Save stays at the bottom while
/// there is something to save.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_header.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_save_bar.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

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

const _channel = Channel(
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
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _viewport = Size(1000, 480);

Future<ScrollController> _open(WidgetTester tester) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container(_Server()),
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: const Column(
              children: [
                SizedBox(height: 200),
                ChannelPermissionsGrid(channel: _channel),
                SizedBox(height: 800),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return scroll;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _header = find.byWidgetPredicate((w) => w is HeaderRow);
final _grid = find.byWidgetPredicate((w) => w is ChannelPermissionsGrid);
final _saveBar = find.byWidgetPredicate((w) => w is SettingsSaveBar);
final _viewCell = find.byKey(
  const ValueKey('cell:role:role-everyone:${Perm.viewChannel}'),
);

void main() {
  testWidgets('the column names ride down with the page', (tester) async {
    final scroll = await _open(tester);
    expect(tester.getRect(_header).top, greaterThan(0), reason: 'at rest');

    scroll.jumpTo(400);
    await _settle(tester);

    expect(
      tester.getRect(_header).top,
      0,
      reason: 'pinned to the top of the view',
    );
    expect(
      tester.getRect(_header).bottom,
      lessThanOrEqualTo(tester.getRect(_grid).bottom),
    );
  });

  testWidgets('Save stays in view after an edit, and still answers a tap', (
    tester,
  ) async {
    final scroll = await _open(tester);
    scroll.jumpTo(tester.getRect(_viewCell).top - 200);
    await _settle(tester);
    await tester.tap(_viewCell);
    await _settle(tester);
    expect(_saveBar, findsOneWidget);

    expect(
      tester.getRect(_saveBar).bottom,
      lessThanOrEqualTo(_viewport.height),
      reason: 'the bar sits below the fold in the layout, but is shown in view',
    );

    await tester.tap(find.text('Discard'));
    await _settle(tester);
    expect(_saveBar, findsNothing);
  });
}
