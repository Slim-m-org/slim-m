// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Guards [AppFocusRing]'s own contract: transparent (but space-reserving)
/// until the wrapped control reports focus, then [AppTokens.focusRing].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Container _outerContainer(WidgetTester tester) =>
    tester.widget<Container>(find.byType(Container).first);

void main() {
  testWidgets('draws no ring, but reserves its space, until focused', (
    tester,
  ) async {
    late ValueChanged<bool> reportFocus;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppFocusRing(
            radius: 6,
            builder: (context, onFocusChange) {
              reportFocus = onFocusChange;
              return const SizedBox(width: 40, height: 40);
            },
          ),
        ),
      ),
    );

    final beforeDecoration =
        _outerContainer(tester).decoration! as BoxDecoration;
    expect(beforeDecoration.border, isA<Border>());
    expect(
      (beforeDecoration.border! as Border).top.color,
      Colors.transparent,
    );
    expect((beforeDecoration.border! as Border).top.width, focusRingWidth);

    reportFocus(true);
    await tester.pump();

    final afterDecoration =
        _outerContainer(tester).decoration! as BoxDecoration;
    expect(
      (afterDecoration.border! as Border).top.color,
      AppTokens.light.focusRing,
    );
  });

  testWidgets('drops the ring again once focus moves elsewhere', (
    tester,
  ) async {
    late ValueChanged<bool> reportFocus;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: AppFocusRing(
            radius: 6,
            builder: (context, onFocusChange) {
              reportFocus = onFocusChange;
              return const SizedBox(width: 40, height: 40);
            },
          ),
        ),
      ),
    );

    reportFocus(true);
    await tester.pump();
    reportFocus(false);
    await tester.pump();

    final decoration = _outerContainer(tester).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.color, Colors.transparent);
  });

  group('presses', () {
    const ring = focusRingGap + focusRingWidth;
    const control = Size(100, 20);
    final belowControl = Offset(ring + 10, control.height + ring + 1);

    Future<void> pumpRing(
      WidgetTester tester, {
      required VoidCallback onControl,
      VoidCallback? onBehind,
      bool touchReach = false,
    }) async {
      final inner = AppFocusRing(
        radius: 6,
        builder: (context, onFocusChange) => InkWell(
          onTap: onControl,
          onFocusChange: onFocusChange,
          child: SizedBox.fromSize(size: control),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBehind,
                  child: const SizedBox.expand(),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: touchReach
                      ? AppTouchHitArea(
                          touch: true,
                          alignment: Alignment.topLeft,
                          child: inner,
                        )
                      : inner,
                ),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('on the control still reach it', (tester) async {
      var taps = 0;
      await pumpRing(tester, onControl: () => taps++);
      await tester.tapAt(const Offset(ring + 10, ring + 10));
      expect(taps, 1);
    });

    testWidgets('in the ring\'s margin fall through to what is behind', (
      tester,
    ) async {
      var taps = 0;
      var behind = 0;
      await pumpRing(tester, onControl: () => taps++, onBehind: () => behind++);
      await tester.tapAt(belowControl);
      expect(taps, 0);
      expect(behind, 1);
    });

    testWidgets(
        'in the ring\'s margin land on a control reached by a touch '
        'area', (tester) async {
      var taps = 0;
      await pumpRing(tester, onControl: () => taps++, touchReach: true);
      await tester.tapAt(belowControl);
      expect(taps, 1);
    });
  });
}
