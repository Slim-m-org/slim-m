// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The window menu kebab closes the menu it opened.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/window_menu_button.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/fake_desktop_window_port.dart';

void main() {
  testWidgets('tapping the kebab a second time closes the window menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: WindowMenuButton(port: FakeDesktopWindowPort()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(AppIcons.moreVertical));
    await tester.pumpAndSettle();
    expect(find.text('Quit slim-m'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.moreVertical));
    await tester.pumpAndSettle();
    expect(
      find.text('Quit slim-m'),
      findsNothing,
      reason: 'second tap on the kebab should close the menu',
    );
  });
}
