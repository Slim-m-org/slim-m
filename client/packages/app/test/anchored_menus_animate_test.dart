// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status, personal space and window menus went through a raw
/// `OverlayPortalController` and appeared and vanished in one frame, unlike
/// the Space menu. Each now plays its exit before it unmounts.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/window_menu_button.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/animated_menu_portal.dart';
import 'package:slimm_app/src/widgets/personal_space_menu.dart';
import 'package:slimm_app/src/widgets/presence_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'desktop/support/fake_desktop_window_port.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _me = api.Me(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  permissions: -1,
);

Future<void> _mount(WidgetTester tester, Widget button) async {
  SharedPreferences.setMockInitialValues(const {});
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      meProvider.overrideWith((ref) async => _me),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(alignment: Alignment.topRight, child: button),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectAnimatedExit(
  WidgetTester tester, {
  required Finder trigger,
  required String item,
}) async {
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  expect(find.text(item), findsOneWidget);
  expect(find.byType(AnimatedMenuSurface), findsOneWidget);

  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 20));
  expect(find.text(item), findsOneWidget, reason: 'still fading out');

  await tester.pumpAndSettle();
  expect(find.text(item), findsNothing);
}

void main() {
  testWidgets('the status menu fades out before it unmounts', (tester) async {
    await _mount(tester, const PresenceMenuButton());
    await _expectAnimatedExit(
      tester,
      trigger: find.byType(PresenceMenuButton),
      item: 'Do not disturb',
    );
  });

  testWidgets('the personal space kebab fades out before it unmounts', (
    tester,
  ) async {
    await _mount(
      tester,
      PersonalSpaceKebab(visible: true, onFocusChange: (_) {}),
    );
    await _expectAnimatedExit(
      tester,
      trigger: find.bySemanticsLabel('Personal space options'),
      item: 'Remove from list',
    );
  });

  testWidgets('the window menu fades out before it unmounts', (tester) async {
    await _mount(tester, WindowMenuButton(port: FakeDesktopWindowPort()));
    await _expectAnimatedExit(
      tester,
      trigger: find.bySemanticsLabel('Window menu'),
      item: 'Quit slim-m',
    );
  });
}
