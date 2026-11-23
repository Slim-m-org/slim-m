// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Geometry of the segmented control: one row at every width, equal shares in a full-width tray.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child, {double width = 390}) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

List<AppSegmentedOption> _levels() => const [
      AppSegmentedOption(label: 'All 3'),
      AppSegmentedOption(label: 'Errors 1'),
      AppSegmentedOption(label: 'Warnings 1'),
      AppSegmentedOption(label: 'Info 1'),
      AppSegmentedOption(label: 'Debug 0'),
    ];

void main() {
  group('AppSegmentedControl.inline rows', () {
    for (final width in [320.0, 360.0, 390.0, 600.0]) {
      testWidgets('five levels lay out on one row at $width', (tester) async {
        await tester.pumpWidget(
          _host(
            AppSegmentedControl.inline(
              options: _levels(),
              selectedIndex: 0,
              onSegmentSelected: (_) {},
            ),
            width: width - 32,
          ),
        );
        final tops = {
          for (final e in find.byType(AnimatedContainer).evaluate())
            tester.getTopLeft(find.byWidget(e.widget)).dy.round(),
        };
        expect(tops, hasLength(1), reason: 'one row only');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a full-width parent gets equal shares across the whole tray', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSegmentedControl.inline(
                options: const [
                  AppSegmentedOption(label: 'Never'),
                  AppSegmentedOption(label: '30 days'),
                ],
                selectedIndex: 0,
                onSegmentSelected: (_) {},
              ),
            ],
          ),
        ),
      );
      final tray = tester.getRect(find.byType(AppSegmentedControl));
      final last = tester.getRect(find.byType(AnimatedContainer).last);
      final first = tester.getRect(find.byType(AnimatedContainer).first);
      expect(tray.right - last.right, closeTo(first.left - tray.left, 0.5));
    });

    testWidgets('labels too long for the floor scroll on one row', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AppSegmentedControl.inline(
            options: [
              for (final l in [
                'Everything',
                'Only mentions',
                'Server maximum',
                'Nothing at all',
                'Custom'
              ])
                AppSegmentedOption(label: l),
            ],
            selectedIndex: 0,
            onSegmentSelected: (_) {},
          ),
          width: 300,
        ),
      );
      final tops = {
        for (final e in find.byType(AnimatedContainer).evaluate())
          tester.getTopLeft(find.byWidget(e.widget)).dy.round(),
      };
      expect(tops, hasLength(1));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });
}
