// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A permissions grid mid-save: the cells stay put, so an edit made while the
/// request is in flight cannot be lost to the reload that follows it.
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

void main() {
  testWidgets('the cells are disabled while a save is in flight', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const send = Perm.sendMessages;
    const react = Perm.addReactions;
    var stored = <(int, int)>[];
    final gate = Completer<void>();
    var puts = 0;
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        puts++;
        await gate.future;
        stored = [(send, 0)];
      }
      return http.Response(
        jsonEncode({
          'overwrites': [
            for (final s in stored)
              {'kind': 'role', 'id': _everyone.id, 'allow': s.$1, 'deny': s.$2},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        rolesProvider.overrideWith((ref) async => [_everyone]),
        membersProvider.overrideWith((ref) async => <api.UserProfile>[]),
        myChannelPermissionsProvider(
          _channel.id,
        ).overrideWith((ref) => send | react),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);
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

    final sendCell = _cell('role:${_everyone.id}', send);
    final reactCell = _cell('role:${_everyone.id}', react);
    await tester.tap(sendCell);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(puts, 1);

    // The save is still in flight: the cell refuses the tap.
    expect(tester.widget<Cell>(reactCell).disabled, isTrue);
    await tester.tap(reactCell, warnIfMissed: false);
    await tester.pump();
    expect(tester.widget<Cell>(reactCell).state, CellState.inherit);

    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.widget<Cell>(reactCell).disabled, isFalse);
    expect(find.textContaining('unsaved'), findsNothing);
  });
}

Finder _cell(String columnKey, int bit) =>
    find.byKey(ValueKey('cell:$columnKey:$bit'));
