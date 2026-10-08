// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space settings gets a bigger panel than other modals (decision 0061), and
/// only its list and grid panes take the wider content cap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';

const _panel = Key('panel');

Future<Rect> _panelAt(WidgetTester tester, Size window, bool space) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => navigator.currentState!.push(
              (space
                      ? modalPage(
                          context,
                          const SizedBox.expand(key: _panel),
                          maxWidth: kSpaceSettingsModalMaxWidth,
                          maxHeight: kSpaceSettingsModalMaxHeight,
                        )
                      : modalPage(context, const SizedBox.expand(key: _panel)))
                  .createRoute(context),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.getRect(find.byKey(_panel));
}

Future<Map<String, double>> _paneWidths(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SettingsPane pane(String id, {bool wide = false}) => SettingsPane(
    id: id,
    label: id,
    wide: wide,
    padding: EdgeInsets.zero,
    builder: (_) => Container(key: Key('content-$id'), height: 40),
  );
  Future<double> widthOf(String id) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: SettingsPanesScaffold(
          title: 'Space settings',
          backTooltip: 'Back',
          backFallback: '/',
          initialPaneId: id,
          groups: [
            SettingsPaneGroup(
              label: 'g',
              panes: [pane('form'), pane('grid', wide: true)],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.getSize(find.byKey(Key('content-$id'))).width;
  }

  return {'form': await widthOf('form'), 'grid': await widthOf('grid')};
}

void main() {
  for (final entry in {
    const Size(1280, 800): 1100.0,
    const Size(1440, 900): 1100.0,
    const Size(1920, 1080): 1100.0,
  }.entries) {
    testWidgets('space settings panel at ${entry.key.width.toInt()} wide '
        'is ${entry.value} and wider than a plain modal', (tester) async {
      final space = await _panelAt(tester, entry.key, true);
      expect(space.width, entry.value);
      expect(space.height, lessThanOrEqualTo(kSpaceSettingsModalMaxHeight));
      expect(space.center.dx, closeTo(entry.key.width / 2, 1));

      final plain = await _panelAt(tester, entry.key, false);
      expect(plain.width, kModalMaxWidth);
      expect(space.width, greaterThan(plain.width));
    });
  }

  testWidgets('a narrow desktop window keeps the panel inside the window', (
    tester,
  ) async {
    final space = await _panelAt(tester, const Size(900, 700), true);
    expect(space.width, lessThanOrEqualTo(900));
  });

  testWidgets('a wide pane takes the wide cap, a form pane keeps 720', (
    tester,
  ) async {
    final widths = await _paneWidths(tester);
    expect(widths['form'], kContentColumnMax);
    expect(widths['grid'], kSettingsWideContentMax);
  });
}
