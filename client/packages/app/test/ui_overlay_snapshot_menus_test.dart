// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gesture-opened menus `ui_overlay_snapshot_test.dart`'s own map cannot
/// reach: each opens from a right-click or long-press over real content
/// rather than an imperative `show*(context, ref)` call, so each gets its
/// own pump here instead of an entry in that file's map.
///
/// Same split as that file: the overflow assertion runs everywhere, the
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/canvas/canvas_object_context_menu.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/space_menu_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'message_row_harness.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _spaceMenuTokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Every item lit, so the render shows the full menu including both
/// danger-toned rows rather than the two ungated ones alone.
const _fullActions = MessageActions(
  canReply: true,
  onReply: noop,
  canEdit: true,
  onEdit: noop,
  canDelete: true,
  onDelete: noop,
  canManagePins: true,
  pinned: false,
  onTogglePin: noop,
  canReport: true,
  onReport: noop,
  canBlockAuthor: true,
  onBlockAuthor: noop,
  canOpenThread: true,
  onOpenThread: noop,
  canCopyLink: false,
  onCopyLink: noop,
  canForward: true,
  onForward: noop,
  canSave: true,
  onSave: noop,
);

/// Not `message_row_harness.dart`'s own `harness()`: that one is built for
/// structural tests and hardcodes a light theme with the debug banner left
/// on, neither of which belongs in a dark, banner-free pixel render matching
/// every other overlay this file's sibling renders.
Future<void> _pumpMessageRow(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: MessageRow(
                message: message(content: 'a message worth acting on'),
                grouped: false,
                showNewDivider: false,
                knownUsernames: const {},
                actions: _fullActions,
                editing: false,
                callbacks: MessageRowCallbacks(
                  onRetry: () {},
                  onDiscard: () {},
                  onPickReaction: (_) {},
                  onReactionTap: (_) {},
                  onVote: (_) {},
                  onSubmitEdit: (_) {},
                  onCancelEdit: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Offset _pressPoint(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
    const Offset(30, 30);

CanvasStrokeInput _shape(String id) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 80,
  h: 60,
  points: const [],
  width: 0,
  colorKey: 'shape',
  kind: CanvasObjectKind.shape,
  authorId: 'me',
);

Future<void> _pumpCanvasObjectMenu(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final document = CanvasDocument()..applyPlaced(_shape('a'));
  addTearDown(document.dispose);

  await tester.pumpWidget(
    RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: window.width,
            height: window.height,
            child: CanvasObjectContextMenu(
              document: document,
              canManage: true,
              selfId: 'me',
              requests: CanvasObjectMenuRequests(),
              tool: CanvasTool.pan,
              onToolChanged: (_) {},
              onBringToFront: (_) {},
              onSendToBack: (_) {},
              onDeleteSelected: (_) {},
              onPasteImageAt: (_) {},
              onAddNoteAt: (_) {},
              onRecenter: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpSpaceMenu(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: _spaceMenuTokens),
      ),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return MessageStore(db);
      }),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path != '/me') return http.Response('{}', 404);
            return http.Response(
              '{"id":"self","username":"self","display_name":"Self",'
              '"created_at":0,"permissions":${Perm.manageChannels}}',
              200,
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
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (context, state) => const Scaffold(
          body: Align(alignment: Alignment.topRight, child: SpaceMenuButton()),
        ),
      ),
      GoRoute(
        path: Routes.spaceSettings,
        builder: (context, state) => const Scaffold(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rail with the shared fixture behind it: it needs the channel store,
/// a session and a router at once, which `ui_snapshot_support.dart` already
/// wires. Stops short of `renderSurface` because the snapshot here has to be
/// taken after a right-click, not on arrival.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpRail(
  WidgetTester tester,
  Size window,
) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: fixtureRouter(Routes.channel('c-general')),
          builder: appChromeBuilder,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('message context menu at phone fits its viewport', (
    tester,
  ) async {
    await _pumpMessageRow(tester, const Size(390, 844));

    await tester.longPressAt(_pressPoint(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await expectSettled(tester, 'message-context-menu-phone');
    await writeSnapshot(tester, 'message-context-menu-phone');
    expect(tester.takeException(), isNull);
  });

  testWidgets('message context menu at desktop fits its viewport', (
    tester,
  ) async {
    await _pumpMessageRow(tester, const Size(1400, 880));

    await tester.tapAt(_pressPoint(tester), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await expectSettled(tester, 'message-context-menu-desktop');
    await writeSnapshot(tester, 'message-context-menu-desktop');
    expect(tester.takeException(), isNull);
  });

  testWidgets('canvas object context menu fits its viewport', (tester) async {
    await _pumpCanvasObjectMenu(tester, const Size(1000, 700));

    await tester.tapAt(const Offset(120, 120), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await expectSettled(tester, 'canvas-object-context-menu');
    await writeSnapshot(tester, 'canvas-object-context-menu');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Space menu fits its viewport', (tester) async {
    await _pumpSpaceMenu(tester, const Size(1400, 880));

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await expectSettled(tester, 'space-menu');
    await writeSnapshot(tester, 'space-menu');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail blank space offers creating a channel', (tester) async {
    final fixture = await _pumpRail(tester, const Size(1400, 880));

    // Below the last row: the blank space the owner asked about, not a row.
    await tester.tapAt(const Offset(160, 780), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Create channel...'), findsOneWidget);
    await expectSettled(tester, 'rail-blank-space-menu');
    await writeSnapshot(tester, 'rail-blank-space-menu');
    expect(tester.takeException(), isNull);
    // The rail's own debounces outlive the tree otherwise; see teardownFixture.
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('the saved messages sheet fits its viewport', (tester) async {
    final fixture = await _pumpRail(tester, const Size(1400, 880));

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Saved messages'));
    await tester.pumpAndSettle();

    expect(find.text('Saved messages'), findsWidgets);
    await expectSettled(tester, 'saved-messages-sheet');
    await writeSnapshot(tester, 'saved-messages-sheet');
    expect(tester.takeException(), isNull);
    await teardownFixture(tester, fixture.container, fixture.db);
  });

  testWidgets('a right-click on a channel row still gets the row menu', (
    tester,
  ) async {
    final fixture = await _pumpRail(tester, const Size(1400, 880));

    // The blank-space menu wraps rows too, so a row's deeper region has to win the arena or every channel's menu is gone.
    final row = find.descendant(
      of: find.byType(ChannelRail),
      matching: find.text('general'),
    );
    await tester.tapAt(tester.getCenter(row), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Open channel'), findsOneWidget);
    expect(find.text('Create channel...'), findsNothing);
    expect(tester.takeException(), isNull);
    await teardownFixture(tester, fixture.container, fixture.db);
  });
}
