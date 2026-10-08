// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An open permissions grid follows an `OverwriteChanged` from another admin,
/// and its header names never paint truncated.
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
import 'package:slimm_app/src/screens/admin/channel_permissions_header.dart';
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
  name: '@everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

final _channel = Channel(
  id: 'c-general',
  name: 'general',
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

class _Harness {
  _Harness(this.stored);

  final Map<String, (int, int)> stored;
  final events = StreamController<api.ServerEvent>.broadcast();

  Future<http.Response> handle(http.Request request) async => http.Response(
    jsonEncode({
      'overwrites': [
        for (final e in stored.entries)
          {
            'kind': e.key.split(':').first,
            'id': e.key.split(':').last,
            'allow': e.value.$1,
            'deny': e.value.$2,
          },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<void> otherAdminChanges(WidgetTester tester) async {
    events.add(api.OverwriteChanged(channelId: _channel.id));
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _open(
  WidgetTester tester,
  Map<String, (int, int)> stored, {
  double width = 390,
  List<api.UserProfile>? members,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = _Harness(stored);
  addTearDown(harness.events.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(harness.events.stream),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith(
        (ref) async =>
            members ?? [_member('m-nadia', 'Nadia'), _member('m-omar', 'Omar')],
      ),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.sendMessages | Perm.addReactions),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(harness.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.listen(roleChangeWatcherProvider, (_, _) {});
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Finder _cell(String columnKey, int bit) =>
    find.byKey(ValueKey('cell:$columnKey:$bit'));

CellState _state(WidgetTester tester, String columnKey, int bit) =>
    tester.widget<Cell>(_cell(columnKey, bit)).state;

Future<void> _tapCell(WidgetTester tester, String columnKey, int bit) async {
  await tester.tap(_cell(columnKey, bit));
  await tester.pumpAndSettle();
}

void main() {
  const send = Perm.sendMessages;
  const react = Perm.addReactions;

  group('live overwrite changes', () {
    testWidgets('another admin changing a cell updates the open grid', (
      tester,
    ) async {
      final harness = await _open(tester, {'member:m-nadia': (0, 0)});
      expect(_state(tester, 'member:m-nadia', send), CellState.inherit);

      harness.stored['member:m-nadia'] = (send, 0);
      await harness.otherAdminChanges(tester);

      expect(_state(tester, 'member:m-nadia', send), CellState.allow);
      expect(find.textContaining('unsaved'), findsNothing);
    });

    testWidgets('a column another admin adds or removes appears or goes', (
      tester,
    ) async {
      final harness = await _open(tester, {'member:m-nadia': (0, 0)});

      harness.stored['member:m-omar'] = (0, send);
      await harness.otherAdminChanges(tester);
      expect(_state(tester, 'member:m-omar', send), CellState.deny);

      harness.stored.remove('member:m-nadia');
      await harness.otherAdminChanges(tester);
      expect(_cell('member:m-nadia', send), findsNothing);
    });

    testWidgets('a cell being edited locally survives the remote change', (
      tester,
    ) async {
      final harness = await _open(tester, {
        'member:m-nadia': (0, 0),
        'member:m-omar': (0, 0),
      });
      await _tapCell(tester, 'member:m-nadia', send);
      expect(find.text('1 unsaved change'), findsOneWidget);

      harness.stored['member:m-nadia'] = (0, send);
      harness.stored['member:m-omar'] = (react, 0);
      await harness.otherAdminChanges(tester);

      expect(_state(tester, 'member:m-nadia', send), CellState.allow);
      expect(_state(tester, 'member:m-omar', react), CellState.allow);
      expect(find.text('1 unsaved change'), findsOneWidget);
    });

    testWidgets('a column removed locally stays removed and counted', (
      tester,
    ) async {
      final harness = await _open(tester, {'member:m-nadia': (0, 0)});
      await tester.tap(find.bySemanticsLabel('Remove Nadia from this grid'));
      await tester.pumpAndSettle();

      harness.stored['member:m-nadia'] = (send, 0);
      await harness.otherAdminChanges(tester);

      expect(_cell('member:m-nadia', send), findsNothing);
      expect(find.text('1 unsaved change'), findsOneWidget);
    });
  });

  group('header names', () {
    testWidgets('always show, stay inside their cell at 360 wide, and the '
        'tooltip carries the full name', (tester) async {
      await _open(
        tester,
        {
          'member:m-ada': (0, 0),
          'member:m-long': (0, 0),
          'member:m-bo': (0, 0),
        },
        width: 360,
        members: [
          _member('m-ada', 'Ada Lovelace'),
          _member('m-long', 'Christopher Longname'),
          _member('m-bo', 'Bo'),
        ],
      );

      for (final label in const ['@everyone', 'Ada Lovelace', 'Bo']) {
        final cell = find.ancestor(
          of: find.byTooltip(label),
          matching: find.byType(HeaderCell),
        );
        expect(cell, findsOneWidget, reason: '$label has no header cell');
        final text = find.descendant(of: cell, matching: find.text(label));
        expect(text, findsOneWidget, reason: '$label name is not painted');
        final rect = tester.getRect(text);
        final bounds = tester.getRect(cell);
        expect(rect.left, greaterThanOrEqualTo(bounds.left), reason: label);
        expect(rect.right, lessThanOrEqualTo(bounds.right), reason: label);
      }
      expect(find.byTooltip('Christopher Longname'), findsOneWidget);
    });
  });
}
