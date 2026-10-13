// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid at phone width: a multi-cell save across principals,
/// the refusal it can hit, and the geometry of the columns.
library;

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

/// An in-memory server: GET returns the stored overwrites, PUT applies the
/// batch, or answers 403 when [refuse] is set.
class _Backend {
  _Backend(this.stored);

  final Map<String, (int, int)> stored;
  bool refuse = false;
  int puts = 0;
  int deletes = 0;

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'DELETE') {
      deletes++;
      stored.remove(request.url.pathSegments.skip(3).take(2).join(':'));
      return http.Response('', 204);
    }
    if (request.method == 'PUT') {
      puts++;
      if (refuse) {
        return http.Response(
          jsonEncode({'error': 'forbidden'}),
          403,
          headers: {'content-type': 'application/json'},
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final o in body['overwrites'] as List<dynamic>) {
        final m = o as Map<String, dynamic>;
        stored['${m['kind']}:${m['id']}'] = (
          m['allow'] as int,
          m['deny'] as int,
        );
      }
    }
    return http.Response(
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
  }
}

Widget _wrap(_Backend backend, {required int myPermissions}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith(
        (ref) async => [
          _member('m-nadia', 'Nadia'),
          _member('m-omar', 'Omar'),
          _member('m-priya', 'Priya'),
          _member('m-quinn', 'Quinn'),
          _member('m-ravi', 'Ravi'),
          _member('m-sana', 'Sana'),
        ],
      ),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => myPermissions),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(backend.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
    ),
  );
}

Finder _cell(String columnKey, int bit) =>
    find.byKey(ValueKey('cell:$columnKey:$bit'));

Future<void> _tapCell(WidgetTester tester, Finder cell) async {
  await tester.ensureVisible(cell);
  await tester.pumpAndSettle();
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a multi-cell save across principals lands and the grid shows '
      'the saved state', (tester) async {
    _phone(tester);
    final backend = _Backend({
      'member:m-nadia': (0, 0),
      'member:m-omar': (0, 0),
    });
    await tester.pumpWidget(
      _wrap(backend, myPermissions: Perm.sendMessages | Perm.addReactions),
    );
    await tester.pumpAndSettle();

    await _tapCell(tester, _cell('role:role-everyone', Perm.sendMessages));
    await _tapCell(tester, _cell('member:m-nadia', Perm.sendMessages));
    await _tapCell(tester, _cell('member:m-nadia', Perm.addReactions));
    await _tapCell(tester, _cell('member:m-omar', Perm.sendMessages));
    await tester.pumpAndSettle();
    expect(find.text('3 unsaved changes'), findsOneWidget);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.puts, 1);
    expect(backend.stored['member:m-nadia'], (
      Perm.sendMessages | Perm.addReactions,
      0,
    ));
    expect(find.textContaining('unsaved'), findsNothing);
    final nadia = tester.widget<Cell>(
      _cell('member:m-nadia', Perm.sendMessages),
    );
    expect(nadia.state, CellState.allow);
  });

  testWidgets('a save that would grant a permission the caller lacks is '
      'refused up front, by name, without a request', (tester) async {
    _phone(tester);
    final backend = _Backend({'member:m-nadia': (0, Perm.sendMessages)});
    await tester.pumpWidget(_wrap(backend, myPermissions: Perm.addReactions));
    await tester.pumpAndSettle();

    await _tapCell(tester, _cell('member:m-nadia', Perm.addReactions));
    await _tapCell(tester, _cell('member:m-nadia', Perm.sendMessages));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(backend.puts, 0);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('Send messages'), findsWidgets);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Save changes'), findsOneWidget);
  });

  testWidgets('three principals fit a 390 phone with nothing clipped and the '
      'touch minimum met', (tester) async {
    _phone(tester);
    final backend = _Backend({
      'member:m-nadia': (0, 0),
      'member:m-omar': (0, 0),
    });
    await tester.pumpWidget(_wrap(backend, myPermissions: Perm.sendMessages));
    await tester.pumpAndSettle();

    final cell = _cell('member:m-omar', Perm.sendMessages);
    final rect = tester.getRect(cell);
    expect(rect.right, lessThanOrEqualTo(390));
    expect(rect.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    final header = tester.getRect(find.text('Omar'));
    expect(header.center.dx, closeTo(rect.center.dx, 1));
    expect(find.byKey(const ValueKey('grid-scroll-more')), findsNothing);
  });

  test('three principals fit the padded phone grid without scrolling', () {
    final metrics = GridMetrics.forWidth(358, columnCount: 3);
    expect(metrics.scrolls, isFalse);
    expect(metrics.cellWidth, greaterThanOrEqualTo(66));
    expect(metrics.addWidth, AppSizes.rowTouch);
    expect(
      metrics.labelWidth + metrics.contentWidth,
      lessThanOrEqualTo(358 + 0.5),
    );
  });

  testWidgets('many principals scroll sideways with the labels pinned and an '
      'edge hint showing', (tester) async {
    _phone(tester);
    final backend = _Backend({
      for (final id in ['nadia', 'omar', 'priya', 'quinn', 'ravi', 'sana'])
        'member:m-$id': (0, 0),
    });
    await tester.pumpWidget(_wrap(backend, myPermissions: Perm.sendMessages));
    await tester.pumpAndSettle();

    final label = find.text('Send messages');
    final labelX = tester.getTopLeft(label).dx;
    expect(find.byKey(const ValueKey('grid-scroll-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-scroll-back')), findsNothing);
    final chevron = find.descendant(
      of: find.byKey(const ValueKey('grid-scroll-more')),
      matching: find.byIcon(AppIcons.chevronRight),
    );
    final firstRow = tester.getRect(find.text('Send messages'));
    expect(tester.getCenter(chevron).dy, closeTo(firstRow.center.dy, 12));

    final last = _cell('member:m-sana', Perm.sendMessages);
    expect(tester.getRect(last).right, greaterThan(390));

    await tester.drag(
      _cell('member:m-nadia', Perm.sendMessages),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(label).dx, labelX);
    final rect = tester.getRect(last);
    expect(rect.left, greaterThanOrEqualTo(GridMetrics.compactLabelWidth));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(find.byKey(const ValueKey('grid-scroll-more')), findsNothing);
    expect(find.byKey(const ValueKey('grid-scroll-back')), findsOneWidget);
    final header = tester.getRect(find.text('Sana'));
    expect(header.center.dx, closeTo(rect.center.dx, 1));
  });

  testWidgets('a cell shows a pressed state while a finger is down', (
    tester,
  ) async {
    _phone(tester);
    final backend = _Backend({'member:m-nadia': (0, 0)});
    await tester.pumpWidget(_wrap(backend, myPermissions: Perm.sendMessages));
    await tester.pumpAndSettle();

    final cell = _cell('member:m-nadia', Perm.sendMessages);
    final chip = find.descendant(of: cell, matching: find.byType(CellChip));
    expect(tester.widget<CellChip>(chip).pressed, isFalse);
    final gesture = await tester.startGesture(tester.getCenter(cell));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<CellChip>(chip).pressed, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<CellChip>(chip).pressed, isFalse);
  });

  testWidgets('a removal that already went through is not sent again after '
      'the batch is refused', (tester) async {
    _phone(tester);
    final backend = _Backend({'member:m-nadia': (0, 0)})..refuse = true;
    await tester.pumpWidget(_wrap(backend, myPermissions: Perm.sendMessages));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Remove Nadia from this grid'));
    await _tapCell(tester, _cell('role:role-everyone', Perm.sendMessages));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Nadia'), findsNothing);
    expect(backend.deletes, 1);

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(backend.deletes, 1);
    expect(backend.puts, 2);
  });
}
