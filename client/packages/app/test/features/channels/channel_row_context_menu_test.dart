// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel row's context menu: opening it always, and reaching "Channel
/// settings..." (name, topic, permissions, delete - `channel_settings_screen.dart`)
/// only for a caller who holds MANAGE_CHANNELS, MANAGE_ROLES, or both.
///
/// The row's kebab is a third way into this exact menu, alongside a
/// right-click and a long-press - backlog item 135, "the kebab on a channel
/// should just expose the context menu; currently outdated code". The kebab
/// used to call `showManageChannelSheet` directly, so a manager's kebab
/// skipped straight past "Open channel" and the mute toggles into the sheet,
/// unlike the identical row's own right-click. The `'the kebab...'` tests
/// below pin that it now reaches the same `channelRowMenuItems` build the
/// other two gestures do.
///
/// "Manage channel..." and "Channel permissions..." used to be two separate
/// entries, each gated on its own bit; they are now one "Channel
/// settings..." entry gated on either bit, which the tests below cover
/// directly (`'either capability...'` group).
///
/// The trailing group covers the regression `channel_rail_reorder.dart`'s
/// own doc comment names: with two or more channels a manager's row is also
/// wrapped in a drag-start listener racing this exact menu's long press for
/// the same held gesture, and the menu used to win every time, making a
/// reorder drag unreachable. A held press must now do nothing on such a
/// row; a right-click must still reach the menu regardless.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

api.Me me(int permissions) => api.Me(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  permissions: permissions,
);

Channel _channel(String id, String name) => Channel(
  id: id,
  name: name,
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

GoRouter _router(Channel channel, {required bool canManage}) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => Scaffold(
        // The real rail watches meProvider; do the same so it stays resolved for the menu, not autoDisposed mid-test.
        body: Consumer(
          builder: (context, ref, _) {
            ref.watch(meProvider);
            return ChannelCategorySections(
              channels: [channel],
              categories: const [],
              selectedId: null,
              canManage: canManage,
              onReorder: (_) {},
            );
          },
        ),
      ),
    ),
    GoRoute(
      path: '/channels/:channelId',
      builder: (context, state) =>
          Scaffold(body: Text('channel:${state.pathParameters['channelId']}')),
    ),
    // A marker, not the real screen: this suite only checks the menu navigated there with the right args.
    GoRoute(
      path: Routes.channelSettings,
      builder: (context, state) {
        final args = state.extra as ChannelSettingsRouteArgs?;
        return Scaffold(
          body: Text('channel-settings:${args?.channel.id}:${args?.wasOpen}'),
        );
      },
    ),
  ],
);

/// Two channels, so `ReorderableChannelRows` actually wraps each row in its
/// drag-start listener - the shape a lone channel above never exercises.
Widget _reorderableHarness({required bool canManage}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: ChannelCategorySections(
        channels: [_channel('c1', 'general'), _channel('c2', 'design')],
        categories: const [],
        selectedId: null,
        canManage: canManage,
        onReorder: (_) {},
      ),
    ),
  ),
);

Widget _harness(GoRouter router, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    );

/// The real rail watches meProvider, keeping it resolved by the time a menu
/// opens; this harness renders the section alone, so force that resolution.
Future<void> _resolveMe(WidgetTester tester) async {
  // The harness watches meProvider; one settle lets the override resolve.
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) => tester.tapAt(
  tester.getCenter(find.text('general')),
  buttons: kSecondaryButton,
  kind: PointerDeviceKind.mouse,
);

void main() {
  testWidgets(
    'a manager sees both Open channel and Channel settings on a right-click',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(_harness(_router(channel, canManage: true)));
      await tester.pump();

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      expect(find.text('Channel settings...'), findsOneWidget);
    },
  );

  testWidgets(
    'every caller, manager or not, sees Mute channel and Mentions only',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(_harness(_router(channel, canManage: false)));
      await tester.pump();

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(
        find.text('Mute channel'),
        findsOneWidget,
        reason: 'muting is a personal preference, not a MANAGE_CHANNELS action',
      );
      expect(find.text('Mentions only'), findsOneWidget);
    },
  );

  group('either capability is enough for Channel settings', () {
    testWidgets('MANAGE_CHANNELS alone shows it, even without MANAGE_ROLES', (
      tester,
    ) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(
        _harness(
          _router(channel, canManage: true),
          overrides: [meProvider.overrideWith((ref) async => me(0))],
        ),
      );
      await _resolveMe(tester);

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Channel settings...'), findsOneWidget);
    });

    testWidgets('MANAGE_ROLES alone shows it, even without MANAGE_CHANNELS', (
      tester,
    ) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(
        _harness(
          _router(channel, canManage: false),
          overrides: [
            meProvider.overrideWith((ref) async => me(Perm.manageRoles)),
          ],
        ),
      );
      await _resolveMe(tester);

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Channel settings...'), findsOneWidget);
    });

    testWidgets('neither capability leaves no Channel settings entry', (
      tester,
    ) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(
        _harness(
          _router(channel, canManage: false),
          overrides: [meProvider.overrideWith((ref) async => me(0))],
        ),
      );
      await _resolveMe(tester);

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      expect(find.text('Channel settings...'), findsNothing);
    });
  });

  testWidgets(
    'a plain member sees only Open channel, the same gate the kebab uses',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(_harness(_router(channel, canManage: false)));
      await tester.pump();

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      expect(
        find.text('Channel settings...'),
        findsNothing,
        reason:
            'MANAGE_CHANNELS/MANAGE_ROLES is what gates the kebab; the menu '
            'must not offer a route around that',
      );
    },
  );

  testWidgets(
    'Channel settings navigates with the channel and whether it was open',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(
        _harness(_router(channel, canManage: true), overrides: []),
      );
      await tester.pump();

      await _openMenu(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();

      expect(find.text('channel-settings:c1:false'), findsOneWidget);
    },
  );

  testWidgets('Open channel navigates to the channel route', (tester) async {
    final channel = _channel('c1', 'general');
    await tester.pumpWidget(_harness(_router(channel, canManage: false)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open channel'));
    await tester.pumpAndSettle();

    expect(find.text('channel:c1'), findsOneWidget);
  });

  testWidgets(
    'the kebab opens the same menu a right-click does, not the settings '
    'route directly',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(_harness(_router(channel, canManage: true)));
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.moreVertical));
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
      expect(find.text('Mute channel'), findsOneWidget);
      expect(find.text('Mentions only'), findsOneWidget);
      expect(find.text('Channel settings...'), findsOneWidget);
      expect(
        find.textContaining('channel-settings:'),
        findsNothing,
        reason:
            'the kebab must open the menu first, not jump straight into '
            'the route its "Channel settings..." item leads to',
      );
    },
  );

  testWidgets(
    'the kebab menu shows Channel settings from MANAGE_CHANNELS alone, even '
    'without MANAGE_ROLES',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(
        _harness(
          _router(channel, canManage: true),
          overrides: [meProvider.overrideWith((ref) async => me(0))],
        ),
      );
      await _resolveMe(tester);

      await tester.tap(find.byIcon(AppIcons.moreVertical));
      await tester.pumpAndSettle();

      expect(find.text('Channel settings...'), findsOneWidget);
    },
  );

  testWidgets(
    'Channel settings from the kebab menu navigates the same route the '
    'right-click menu does',
    (tester) async {
      final channel = _channel('c1', 'general');
      await tester.pumpWidget(_harness(_router(channel, canManage: true)));
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.moreVertical));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel settings...'));
      await tester.pumpAndSettle();

      expect(find.text('channel-settings:c1:false'), findsOneWidget);
    },
  );

  testWidgets(
    "Mute channel from the kebab menu runs the same action the right-click "
    "menu's own item does",
    (tester) async {
      final channel = _channel('c1', 'general');
      const tokens = api.TokenPair(
        userId: 'u-me',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 4102444800000,
      );
      await tester.pumpWidget(
        _harness(
          _router(channel, canManage: true),
          overrides: [
            sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
            mockApiOverride((request) async {
              if (request.url.path.startsWith(
                    '/notification-preferences/channels/',
                  ) &&
                  request.method == 'PUT') {
                return http.Response(
                  jsonEncode({
                    'channel_id': request.url.pathSegments.last,
                    'preference': 'nothing',
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response(
                jsonEncode(const <Object>[]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(AppIcons.moreVertical));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute channel'));
      await tester.pumpAndSettle();

      expect(find.byIcon(AppIcons.notificationsOff), findsOneWidget);
    },
  );

  testWidgets(
    'a held press on a reorderable row starts a drag rather than opening '
    'the menu',
    (tester) async {
      await tester.pumpWidget(_reorderableHarness(canManage: true));
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('general')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);

      expect(
        find.text('Open channel'),
        findsNothing,
        reason: 'the drag listener must win the arena, not the menu',
      );

      await gesture.moveBy(const Offset(0, 200));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        find.text('Open channel'),
        findsNothing,
        reason: 'a completed drag must not leave the menu open either',
      );
    },
  );

  testWidgets('a right-click still reaches the menu on a reorderable row', (
    tester,
  ) async {
    await tester.pumpWidget(_reorderableHarness(canManage: true));
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.text('general')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('Open channel'), findsOneWidget);
    expect(find.text('Channel settings...'), findsOneWidget);
  });

  testWidgets(
    'a held press still opens the menu when the row is not reorderable',
    (tester) async {
      // Not reorderable, so ReorderableChannelRows uses a plain column here.
      await tester.pumpWidget(_reorderableHarness(canManage: false));
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('general')),
      );
      await tester.pump(kLongPressTimeout + kPressTimeout);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Open channel'), findsOneWidget);
    },
  );
}
