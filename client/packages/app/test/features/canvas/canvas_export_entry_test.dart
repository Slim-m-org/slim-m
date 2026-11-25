// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overflow menu's "Export canvas..." row: which boards and viewers see it, where it sits, and that it opens the sheet.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_module_tile_scope.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../ui_snapshot_support.dart' show teardownFixture;

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Future<void> _openMenu(
  WidgetTester tester, {
  String kind = 'voice',
  bool canvasEnabled = true,
  bool exportCapability = true,
  bool readOnly = false,
  bool canManage = true,
  bool withScope = true,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await tester.runAsync(
    () => store.upsertChannels([
      api.Channel.fromJson({
        'id': 'board',
        'name': 'minecraft',
        'kind': kind,
        'created_at': 0,
        'canvas_enabled': canvasEnabled,
      }),
    ]),
  );
  Widget menu() => CanvasOverflowMenu(
    canDraw: true,
    onToggleFullscreen: () {},
    canManage: canManage,
    onClear: () async {},
    selection: ValueNotifier(null),
    onBringToFront: (_) {},
    onSendToBack: (_) {},
    onDeleteSelected: (_) {},
    activityLogOpen: false,
    onToggleActivityLog: () {},
    tool: CanvasTool.pan,
    shapeKind: CanvasShapeKind.rectangle,
    onShapeKindChanged: (_) {},
    hasSelfBubble: false,
    selfBubbleHidden: false,
    onToggleSelfBubbleHidden: () {},
    hiddenTiles: const [],
    onShowTile: (_) {},
    readOnly: readOnly,
  );
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      myPermissionsProvider.overrideWithValue(Perm.manageChannels),
      myChannelPermissionsProvider('board').overrideWithValue(0),
      mockApiOverride((request) async {
        return http.Response(
          jsonEncode({
            'name': 's',
            'version': '1',
            'protocol': 1,
            'capabilities': [if (exportCapability) 'canvas_export'],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    ],
  );
  _finishers.add(() => teardownFixture(tester, container, db));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: withScope
                ? CanvasModuleTileScope(
                    channelId: 'board',
                    onPlace: null,
                    child: menu(),
                  )
                : menu(),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester, frames: 30);
  await tester.tap(find.bySemanticsLabel('More canvas actions'));
  await pumpFrames(tester, frames: 30);
}

final _finishers = <Future<void> Function()>[];

/// A test whose store streams are let go inside it, before the framework checks for stray timers.
void _test(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final finish in _finishers) {
        await finish();
      }
      _finishers.clear();
    }
  });
}

void main() {
  _test('a voice canvas on a server that exports offers the row above Clear', (
    tester,
  ) async {
    await _openMenu(tester);

    expect(find.text('Export canvas...'), findsOneWidget);
    final export = tester.getRect(find.text('Export canvas...'));
    final clear = tester.getRect(find.text('Clear canvas'));
    expect(export.top, lessThan(clear.top));
    expect(export.left, clear.left, reason: 'one column of rows');
  });

  _test(
    'a canvas channel offers it, and without MANAGE_CANVAS the row stays alone',
    (tester) async {
      await _openMenu(tester, kind: 'canvas', canManage: false);

      expect(find.text('Export canvas...'), findsOneWidget);
      expect(find.text('Clear canvas'), findsNothing);
    },
  );

  _test('a server that cannot export offers no row, and no stray divider', (
    tester,
  ) async {
    await _openMenu(tester, exportCapability: false, canManage: false);

    expect(find.text('Export canvas...'), findsNothing);
  });

  _test(
    'a direct message, a text channel and a closed voice canvas offer none',
    (tester) async {
      await _openMenu(tester, kind: 'dm');
      expect(find.text('Export canvas...'), findsNothing);
    },
  );

  _test('a voice channel with its canvas off offers none', (tester) async {
    await _openMenu(tester, canvasEnabled: false);
    expect(find.text('Export canvas...'), findsNothing);
  });

  _test('a spectator never sees it', (tester) async {
    await _openMenu(tester, readOnly: true);
    expect(find.text('Export canvas...'), findsNothing);
  });

  _test('outside a board it offers nothing', (tester) async {
    await _openMenu(tester, withScope: false);
    expect(find.text('Export canvas...'), findsNothing);
  });

  _test('choosing it closes the menu and opens the sheet', (tester) async {
    await _openMenu(tester);

    await tester.tap(find.text('Export canvas...'));
    await pumpFrames(tester, frames: 40);

    expect(find.text('Export canvas'), findsOneWidget);
    expect(find.text('Export canvas...'), findsNothing);
  });
}
