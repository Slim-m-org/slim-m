// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Create emoji is a short task with a submit (desktop-vs-mobile rule 4): a
/// dialog over the Space settings panel on desktop, a bottom sheet on a phone.
/// It used to push a full-window page over the floating panel.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/emoji_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/routing/settings_pages.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import 'emoji_add_harness.dart' show emojiTestPng;
import 'settings_harness.dart' show allPermissionBits;

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _json = {'content-type': 'application/json'};

Future<http.Response> _answer(http.Request request) async {
  final path = request.url.path;
  if (path == '/emoji') {
    return http.Response(
      jsonEncode([
        {
          'id': 'e1',
          'name': 'huh',
          'uploader_id': 'self',
          'created_at': 1700000000000,
        },
      ]),
      200,
      headers: _json,
    );
  }
  if (path.endsWith('/image')) {
    return http.Response.bytes(
      emojiTestPng,
      200,
      headers: const {'content-type': 'image/png'},
    );
  }
  if (path == '/space/settings') {
    return http.Response(
      jsonEncode({'join_policy': 'invite'}),
      200,
      headers: _json,
    );
  }
  if (path == '/me') {
    return http.Response(
      jsonEncode({
        'id': 'self',
        'username': 'self',
        'display_name': 'Self',
        'created_at': 0,
        'permissions': allPermissionBits,
      }),
      200,
      headers: _json,
    );
  }
  return http.Response(
    path == '/devices' || path == '/blocks' ? '[]' : '{}',
    path == '/devices' || path == '/blocks' ? 200 : 404,
    headers: _json,
  );
}

Future<void> _pumpEmoji(WidgetTester tester, Size size) async {
  GoRouter.optionURLReflectsImperativeAPIs = true;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final phone = size.width < kCompactWidth;
  final target = phone ? Routes.adminEmoji : Routes.spaceSettingsPane('emoji');
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: TextButton(
            onPressed: () => context.push(target),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(path: Routes.spaceSettings, pageBuilder: spaceSettingsPage),
      GoRoute(
        path: Routes.adminEmoji,
        pageBuilder: (context, state) =>
            modalPage(context, const EmojiScreen()),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride(_answer),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await _frames(tester);
  await tester.tap(find.text('open'));
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final size in const [_desktop, _phone]) {
    final width = size.width.toInt();

    testWidgets('Add keeps the emoji list on screen behind it at $width', (
      tester,
    ) async {
      await _pumpEmoji(tester, size);
      expect(find.text('Emoji (1)'), findsOneWidget);

      await tester.tap(find.text('Add'));
      await _frames(tester);

      expect(find.text('Choose files'), findsOneWidget);
      expect(
        find.text('Emoji (1)'),
        findsOneWidget,
        reason: 'a dialog or sheet leaves the pane painted behind it',
      );
    });

    testWidgets('a click outside the Create emoji surface closes only it at '
        '$width', (tester) async {
      await _pumpEmoji(tester, size);
      await tester.tap(find.text('Add'));
      await _frames(tester);
      expect(find.text('Choose files'), findsOneWidget);

      await tester.tapAt(Offset(size.width - 4, 30));
      await _frames(tester);

      expect(find.text('Choose files'), findsNothing);
      expect(find.text('Emoji (1)'), findsOneWidget);
    });

    testWidgets('Escape closes Create emoji and leaves the pane at $width', (
      tester,
    ) async {
      await _pumpEmoji(tester, size);
      await tester.tap(find.text('Add'));
      await _frames(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);

      expect(find.text('Choose files'), findsNothing);
      expect(find.text('Emoji (1)'), findsOneWidget);
    });
  }

  testWidgets('on desktop Create emoji is a narrow dialog, not a page', (
    tester,
  ) async {
    await _pumpEmoji(tester, _desktop);
    await tester.tap(find.text('Add'));
    await _frames(tester);

    final title = tester.getRect(find.text('Create emoji'));
    final choose = tester.getRect(find.text('Choose files'));
    final centre = _desktop.width / 2;
    expect(title.left, greaterThan(centre - kSheetMaxWidth / 2));
    expect(choose.right, lessThan(centre + kSheetMaxWidth / 2));
  });

  testWidgets('on a phone Create emoji sits against the bottom edge', (
    tester,
  ) async {
    await _pumpEmoji(tester, _phone);
    await tester.tap(find.text('Add'));
    await _frames(tester);

    final choose = tester.getRect(find.text('Choose files'));
    final title = tester.getRect(find.text('Create emoji'));
    expect(
      title.top,
      greaterThan(_phone.height / 2),
      reason: 'a sheet leaves the top of the screen to the page behind it',
    );
    expect(choose.bottom, lessThan(_phone.height));
  });
}
