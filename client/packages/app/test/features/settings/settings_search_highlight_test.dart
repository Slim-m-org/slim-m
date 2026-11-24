// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A search highlight that no row consumed does not linger and light a row
/// later: not when a draft refuses the pane switch, not when no target mounts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_search.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_sub_pages.dart';
import 'package:slimm_design_system/design_system.dart';

class _Refusing implements SettingsLeaveGuard {
  bool answer = false;

  @override
  bool get blocking => true;

  @override
  Future<bool> confirmLeave() async => answer;
}

class _DraftPane extends StatefulWidget {
  const _DraftPane(this.guard);

  final _Refusing guard;

  @override
  State<_DraftPane> createState() => _DraftPaneState();
}

class _DraftPaneState extends State<_DraftPane> {
  @override
  void initState() {
    super.initState();
    SettingsSubPages.of(context).setPaneGuard(widget.guard);
  }

  @override
  Widget build(BuildContext context) => const Text('pane-a');
}

bool _lit(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byType(SettingsHighlightTarget),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return (box.decoration! as BoxDecoration).color!.a > 0;
}

void main() {
  testWidgets('a refused pane switch leaves no highlight behind', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final guard = _Refusing();
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData.fromView(tester.view),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: SettingsPanesScaffold(
            title: 'Settings',
            backTooltip: 'Back',
            backFallback: '/',
            initialPaneId: 'a',
            searchEntries: const [SettingsEntry('b', 'Probe row')],
            groups: [
              SettingsPaneGroup(
                label: 'You',
                panes: [
                  SettingsPane(
                    id: 'a',
                    label: 'First',
                    builder: (_) => _DraftPane(guard),
                  ),
                  SettingsPane(
                    id: 'b',
                    label: 'Second',
                    builder: (_) => const SettingsHighlightTarget(
                      label: 'Probe row',
                      child: Text('pane-b'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('settings-search')), 'probe');
    await tester.pump();
    await tester.tap(find.text('Probe row'));
    await tester.pumpAndSettle();
    expect(
      find.text('pane-a'),
      findsOneWidget,
      reason: 'the switch was refused',
    );

    guard.answer = true;
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('pane-b'), findsOneWidget);
    expect(_lit(tester), isFalse);
  });
}
