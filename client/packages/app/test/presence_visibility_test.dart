// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fresh launch shows the caller's own state from what the server reports.
///
/// The preference is durable server-side (`users.presence_visibility`,
/// migration 0008), and no endpoint returns it: `PATCH /presence` echoes only
/// what it just set and `GET /presence` resolves the caller's own id to their
/// true connection state. So a fresh session reads the reported state, and a
/// choice made this session wins over it so the footer answers the tap.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/presence_menu.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(StubSyncController.new),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((request) async {
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'PATCH' && request.url.path == '/presence') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({'visibility': body['visibility']}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

/// `/presence` refuses every request; `/me` still answers so the footer has
/// a caller to render.
ProviderContainer _containerFailingPresence() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(StubSyncController.new),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((request) async {
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path == '/presence') {
            return http.Response(
              '{}',
              500,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

/// Wide by default, matching every test below that never mentions width:
/// this is the anchored-`AppMenu` case per `docs/design/desktop-vs-mobile.md`.
/// [compact] drops under `kCompactWidth` for the bottom-sheet case instead.
Future<void> _pumpFooter(
  WidgetTester tester,
  ProviderContainer container, {
  bool compact = false,
}) async {
  tester.view.physicalSize = compact
      ? const Size(390, 800)
      : const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomLeft, child: RailUserFooter()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('a fresh session starts with no known visibility', () {
    final container = _container();
    addTearDown(container.dispose);

    expect(
      container.read(presenceVisibilityDisplayProvider),
      isNull,
      reason:
          'defaulting to online asserts a stored choice this client has '
          'no endpoint to read back',
    );
  });

  testWidgets('before any choice the footer reports what the server says '
      'about the caller, never "unknown"', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('unknown'), findsNothing);
    expect(find.text('connected'), findsNothing);
    expect(find.text('online'), findsOneWidget);
  });

  testWidgets('the status menu marks the caller\'s current state', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();

    final items = tester
        .widgetList<AppMenuItem>(
          find.descendant(
            of: find.byType(AppMenu),
            matching: find.byType(AppMenuItem),
          ),
        )
        .where((item) => presenceOptions.any((o) => o.$2 == item.label));
    expect(items, hasLength(presenceOptions.length));
    expect(items.where((item) => item.selected).map((i) => i.label), [
      'Online',
    ]);
  });

  testWidgets('a choice made in this session is shown as current', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.hidden;
    await _pumpFooter(tester, container);

    expect(find.text('appearing offline'), findsOneWidget);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();

    final selected = tester
        .widgetList<AppMenuItem>(
          find.descendant(
            of: find.byType(AppMenu),
            matching: find.byType(AppMenuItem),
          ),
        )
        .where((item) => item.selected);
    expect(selected.map((item) => item.label), ['Appear offline']);
  });

  testWidgets('a refused change restores the previous choice and shows why, '
      'without closing the menu over it', (tester) async {
    final container = _containerFailingPresence();
    addTearDown(container.dispose);
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.away;
    await _pumpFooter(tester, container);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appear offline'));
    await tester.pumpAndSettle();

    expect(
      container.read(presenceVisibilityDisplayProvider),
      api.PresenceVisibility.away,
      reason:
          'a refusal must never leave the echo asserting a visibility the '
          'server never applied',
    );
    expect(find.byType(AppErrorState), findsOneWidget);
    // Still open: closing it now would hide the one place showing the error.
    expect(find.byType(AppMenu), findsOneWidget);
  });

  testWidgets('the status menu stays an anchored AppMenu on a wide window', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();

    expect(find.byType(AppMenu), findsOneWidget);
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'a wide window has room for the anchored menu it always had',
    );
  });

  testWidgets(
    'the status menu opens as a bottom sheet under kCompactWidth, with the '
    'same items',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpFooter(tester, container, compact: true);

      await tester.tap(find.byType(UserAvatar));
      await tester.pumpAndSettle();

      expect(
        find.byType(BottomSheet),
        findsOneWidget,
        reason: 'an anchored surface under a thumb is the exact bug this fixes',
      );
      expect(
        find.byType(AppMenu),
        findsNothing,
        reason: 'the sheet renders the bare AppSheetMenu column, not a card',
      );
      expect(find.text('Set a status'), findsOneWidget);
      expect(find.byType(AppMenuDivider), findsOneWidget);
      final items = tester
          .widgetList<AppMenuItem>(find.byType(AppMenuItem))
          .where((item) => presenceOptions.any((o) => o.$2 == item.label));
      expect(items, hasLength(presenceOptions.length));
    },
  );

  testWidgets(
    'selecting a status from the compact sheet still updates presence and '
    'closes it',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpFooter(tester, container, compact: true);

      await tester.tap(find.byType(UserAvatar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appear offline'));
      await tester.pumpAndSettle();

      expect(
        container.read(presenceVisibilityDisplayProvider),
        api.PresenceVisibility.hidden,
      );
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  testWidgets(
    'a refused change from the compact sheet shows why, without closing it',
    (tester) async {
      final container = _containerFailingPresence();
      addTearDown(container.dispose);
      await _pumpFooter(tester, container, compact: true);

      await tester.tap(find.byType(UserAvatar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appear offline'));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );

  testWidgets(
    'opening the status editor from the compact sheet closes the sheet and '
    'opens the editor',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpFooter(tester, container, compact: true);

      await tester.tap(find.byType(UserAvatar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set a status'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('What are you up to?'), findsOneWidget);
    },
  );

  testWidgets('the footer stays one row tall and its menu opens above it in a '
      'bounded-height parent', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    final footerHeight = tester.getSize(find.byType(RailUserFooter)).height;
    expect(
      footerHeight,
      lessThan(80),
      reason: 'the avatar tap area must not grow to fill a bounded parent',
    );

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.byType(AppMenu));
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(
      menu.bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(UserAvatar)).dy),
    );
  });
}
