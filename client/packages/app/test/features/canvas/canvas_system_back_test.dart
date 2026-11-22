// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// System Back on a phone steps out of the canvas one layer at a time.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

Future<void> _back(WidgetTester tester) async {
  expect(await tester.binding.handlePopRoute(), isTrue);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'back leaves fullscreen, then closes the canvas, then pops the route',
    (tester) async {
      final fixture = await fixtureContainer(
        extraOverrides: [
          canvasOpenProvider.overrideWith((ref) => 'c-general'),
          canvasFullscreenProvider.overrideWith((ref) => 'c-general'),
        ],
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter('/channels/c-general'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final container = fixture.container;

      await _back(tester);
      expect(container.read(canvasFullscreenProvider), isNull);
      expect(container.read(canvasOpenProvider), 'c-general');

      await _back(tester);
      expect(container.read(canvasOpenProvider), isNull);

      await _back(tester);
      expect(await tester.binding.handlePopRoute(), isFalse);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
