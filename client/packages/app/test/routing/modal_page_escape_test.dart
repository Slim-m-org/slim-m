// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Escape closes a modal page whichever control inside it holds focus.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_design_system/design_system.dart';

const _toggleLabel = 'Automatic sensitivity';

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => navigator.currentState!.push(
                modalPage(
                  context,
                  SettingsPanesScaffold(
                    title: 'Settings',
                    backTooltip: 'Back',
                    backFallback: '/',
                    initialPaneId: 'voice',
                    groups: [
                      SettingsPaneGroup(
                        label: 'g',
                        panes: [
                          SettingsPane(
                            id: 'voice',
                            label: 'Voice',
                            builder: (_) => Center(
                              child: AppToggle(
                                value: false,
                                onChanged: (_) {},
                                semanticLabel: _toggleLabel,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ).createRoute(context),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('Escape closes a modal page after a toggle was clicked', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.bySemanticsLabel(_toggleLabel));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.bySemanticsLabel(_toggleLabel), findsNothing);
  });
}
