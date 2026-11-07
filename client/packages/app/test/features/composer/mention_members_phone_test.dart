// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone no member pane is mounted, so typing @ in the composer is the
/// first thing that asks for the roster; members must still be offered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'typing @ on a phone offers members, not only @everyone',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      addTearDown(tester.view.reset);
      final fixture = await fixtureContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter('/channels/c-general'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.showKeyboard(find.byType(EditableText).last);
      await tester.enterText(find.byType(EditableText).last, '@');
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final list = find.byType(ComposerAutocomplete);
      expect(list, findsOneWidget, reason: 'the suggestion list is open');
      final box = tester.getRect(list);
      final ada = tester.getRect(
        find.descendant(of: list, matching: find.text('@ada')),
      );
      // ignore: avoid_print
      print('LIST $box ADA $ada');
      expect(box.contains(ada.center), isTrue, reason: 'a member is on screen');
      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
