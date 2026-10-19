// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The settings sidebar never lets the pinned Sign out row sit on top of a nav
/// row, however short the window: the list above it scrolls instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/features/settings/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_hairline.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../support/fake_api.dart';

Future<void> _open(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        mockApiOverride((_) async => throw StateError('unexpected call')),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => navigator.currentState!.push(
              modalPage(
                context,
                const PersonalSettingsScreen(),
              ).createRoute(context),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Rect _row(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(AppListRow)),
);

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  for (final window in const [Size(1280, 800), Size(1280, 600)]) {
    testWidgets(
      'no nav row is cut by Sign out at ${window.width}x${window.height}',
      (tester) async {
        await _open(tester, window);
        final signOut = tester.getRect(find.text('Sign out'));
        final list = tester.getRect(find.byType(ListView).first);

        final rules = find
            .byType(SettingsHairline)
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .where((r) => r.left < list.right && r.top >= list.bottom);
        expect(
          rules.any((r) => r.bottom <= signOut.top),
          isTrue,
          reason: 'a rule between the scrolling list and Sign out',
        );
        await tester.dragUntilVisible(
          find.text('About slim-m'),
          find.byType(ListView).first,
          const Offset(0, -80),
        );
        await tester.pumpAndSettle();
        final about = _row(tester, 'About slim-m');
        expect(about.bottom, lessThanOrEqualTo(list.bottom));
        expect(about.bottom, lessThanOrEqualTo(signOut.top));
      },
    );
  }

  testWidgets('the rail fades its bottom edge while rows sit below it', (
    tester,
  ) async {
    await _open(tester, const Size(1280, 600));
    double fade() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('settings-rail-fade')),
        )
        .opacity;
    expect(fade(), 1);

    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(fade(), 0);
  });
}
