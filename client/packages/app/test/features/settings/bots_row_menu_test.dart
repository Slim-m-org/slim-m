// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot is one line, and its actions live in one menu that the kebab, a
/// right-click and a long press all open.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/bot_menu.dart';
import '../../support/fake_api.dart';
import '../../support/menu_gestures.dart';

Map<String, Object?> _bot(
  String name, {
  String handle = 'helper',
  bool online = false,
  bool revoked = false,
}) => {
  'user_id': 'bot-$handle',
  'username': handle,
  'display_name': name,
  'created_at': 0,
  'token_name': revoked ? null : 'T',
  'token_last_used_at': null,
  'role_id': revoked ? null : 'role',
  'permissions': 3,
  'online': online,
  'prefix': '!',
};

final _bots = [
  _bot('helper', online: true),
  _bot('warns', handle: 'warns'),
  _bot('Weekly digest assistant for the whole community', handle: 'digest'),
  _bot('quotes', handle: 'a_really_long_bot_handle_that_keeps_going_xx'),
  _bot('gone', handle: 'gone', revoked: true),
];

Finder _row(String userId) => find.byKey(ValueKey(userId));

Future<List<String>> _pump(WidgetTester tester, {required double width}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final posted = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'user-1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride(
        withSpaceSettings((request) {
          if (request.method == 'POST') posted.add(request.url.path);
          if (request.url.path == '/bots') {
            return http.Response(
              jsonEncode(_bots),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const BotsScreen(),
      ),
    ),
  );
  await pumpFrames(tester);
  return posted;
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('at $width wide each bot is one row of the card row height', (
      tester,
    ) async {
      await _pump(tester, width: width);

      final rects = [
        for (final bot in _bots)
          tester.getRect(_row(bot['user_id']! as String)),
      ];
      for (final rect in rects) {
        expect(rect.height, AppCardRowScope.minHeight);
      }
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom));
      }
      expect(rects.last.bottom - rects.first.top, lessThan(5 * 60));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the kebab stays inside its row and is a touch-sized target', (
    tester,
  ) async {
    await _pump(tester, width: 390);

    final row = tester.getRect(_row('bot-helper'));
    final kebab = tester.getRect(find.byIcon(AppIcons.moreVertical).first);
    expect(row.contains(kebab.center), isTrue);
    expect(kebab.right, lessThanOrEqualTo(row.right));
    expect(row.height, greaterThanOrEqualTo(AppSizes.rowTouch));
  });

  testWidgets('a long name never pushes the connection dot off the row', (
    tester,
  ) async {
    await _pump(tester, width: 390);

    const longName = 'bot-digest';
    final dot = tester.getRect(
      find.byKey(const ValueKey('bot-presence-$longName')),
    );
    final row = tester.getRect(_row(longName));
    final kebab = tester.getRect(find.byIcon(AppIcons.moreVertical).at(2));
    expect(dot.right, lessThanOrEqualTo(kebab.left));
    expect(dot.left, greaterThan(row.left));
    expect(find.byKey(const ValueKey('bot-presence-bot-gone')), findsNothing);
  });

  testWidgets('a large text size keeps every bot on its own row', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final reported = <String>[];
    final handler = FlutterError.onError;
    FlutterError.onError = (details) => reported.add(details.toString());
    try {
      await _pump(tester, width: 390);
    } finally {
      FlutterError.onError = handler;
    }

    final rects = [
      for (final bot in _bots) tester.getRect(_row(bot['user_id']! as String)),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom));
    }
    expect(reported.where((e) => e.contains('bot_row.dart')), isEmpty);
  });

  Future<void> expectBotMenu(WidgetTester tester) async {
    final labels = ['Permissions', 'Prefix', 'Re-issue token', 'Revoke'];
    final tops = [
      for (final label in labels) tester.getTopLeft(botMenuItem(label)).dy,
    ];
    expect(tops, [...tops]..sort(), reason: 'Revoke comes last');
    expect(
      tester.widget<AppMenuItem>(botMenuItem('Revoke')).tone,
      AppMenuItemTone.danger,
    );
  }

  testWidgets('a second press on the kebab closes the open menu', (
    tester,
  ) async {
    await _pump(tester, width: 1280);

    await openBotMenu(tester);
    await expectBotMenu(tester);

    await openBotMenu(tester);
    expect(botMenuItem('Revoke'), findsNothing);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('at $width the kebab opens the menu', (tester) async {
      await _pump(tester, width: width);

      await openBotMenu(tester);
      await expectBotMenu(tester);
    });

    testWidgets('at $width a right-click on the row opens the same menu', (
      tester,
    ) async {
      await _pump(tester, width: width);

      await rightClickMenu(tester, find.textContaining('@warns'));
      await expectBotMenu(tester);
    });

    testWidgets('at $width a long press on the row opens the same menu', (
      tester,
    ) async {
      await _pump(tester, width: width);

      await longPressMenu(tester, find.textContaining('@warns'));
      await expectBotMenu(tester);
    });
  }

  Future<List<String>> openRevoke(WidgetTester tester) async {
    final posted = await _pump(tester, width: 390);
    await openBotMenu(tester, index: 1);
    await tester.tap(botMenuItem('Revoke'));
    await pumpFrames(tester, frames: 30);
    return posted;
  }

  testWidgets('Revoke asks first and posts nothing until it is confirmed', (
    tester,
  ) async {
    final posted = await openRevoke(tester);

    expect(find.text('Revoke warns?'), findsOneWidget);
    expect(posted, isEmpty);
  });

  testWidgets('confirming Revoke revokes the bot the menu belongs to', (
    tester,
  ) async {
    final posted = await openRevoke(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Revoke').last);
    await pumpFrames(tester, frames: 30);

    expect(posted, ['/bots/bot-warns/revoke']);
  });

  testWidgets('cancelling Revoke revokes nothing', (tester) async {
    final posted = await openRevoke(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await pumpFrames(tester, frames: 30);

    expect(posted, isEmpty);
    expect(find.text('Revoke warns?'), findsNothing);
  });

  testWidgets('Permissions opens the permission sheet for that bot', (
    tester,
  ) async {
    await _pump(tester, width: 390);

    await openBotMenu(tester);
    await tester.tap(botMenuItem('Permissions'));
    await pumpFrames(tester, frames: 30);

    expect(find.text("helper's permissions"), findsOneWidget);
    expect(botMenuItem('Permissions'), findsNothing);
  });

  testWidgets('Prefix opens the prefix sheet and Re-issue token its confirm', (
    tester,
  ) async {
    final posted = await _pump(tester, width: 1280);

    await openBotMenu(tester);
    await tester.tap(botMenuItem('Prefix'));
    await pumpFrames(tester, frames: 30);
    expect(find.text("helper's prefix"), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.dismiss));
    await pumpFrames(tester, frames: 30);

    await openBotMenu(tester);
    await tester.tap(botMenuItem('Re-issue token'));
    await pumpFrames(tester, frames: 30);
    expect(find.text("Re-issue helper's token?"), findsOneWidget);
    expect(posted, isEmpty);
  });

  testWidgets('a revoked bot can only be re-issued a token', (tester) async {
    await _pump(tester, width: 390);

    await openBotMenu(tester, index: 4);
    expect(botMenuItem('Re-issue token'), findsOneWidget);
    for (final label in ['Permissions', 'Prefix', 'Revoke']) {
      expect(botMenuItem(label), findsNothing);
    }
  });
}
