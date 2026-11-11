// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Center(child: AppMenu(width: 300, children: [child])),
      ),
    );

void main() {
  testWidgets('a filled segmented control spans the menu content width', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        AppMenuSegmentedRow(
          label: 'Quality',
          options: const [
            AppSegmentedOption(label: '360p'),
            AppSegmentedOption(label: '720p'),
            AppSegmentedOption(label: '1080p'),
          ],
          selectedIndex: 1,
          onSelected: (i) => picked = i,
        ),
      ),
    );
    final menu = tester.getRect(find.byType(AppMenu));
    final control = tester.getRect(find.byType(AppSegmentedControl));
    expect(control.left - menu.left, 1 + 6 + kMenuContentInset);
    expect(menu.right - control.right, 1 + 6 + kMenuContentInset);

    await tester.tap(find.text('1080p'));
    expect(picked, 2);
  });

  testWidgets('a switch row toggles from anywhere on the row', (tester) async {
    var value = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, set) => AppMenuSwitchRow(
            label: 'Mirror my view',
            value: value,
            onChanged: (v) => set(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mirror my view'));
    await tester.pump();
    expect(value, isTrue);
    expect(tester.widget<AppToggle>(find.byType(AppToggle)).value, isTrue);
  });
}
