// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RailDragHandle]'s hover feedback: the hairline (and, collapsed, the
/// glyph) travel on one lerped clock rather than swapping colour in a frame.
/// Shipped by #606 alongside the rest of the design system's hover tempo,
/// but that change pinned every other widget it touched with a test of its
/// own and left this one uncovered - closed here.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/rail_drag_handle.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {bool reduceMotion = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: const Scaffold(body: RailDragHandle(railWidth: 248)),
        ),
      ),
    ),
  );
}

Color? _hairlineColor(WidgetTester tester) =>
    tester.widget<VerticalDivider>(find.byType(VerticalDivider)).color;

void main() {
  testWidgets(
    'hovering the open handle lerps the hairline rather than snapping it',
    (tester) async {
      // Touch mode (the test default) suppresses FocusableActionDetector hover.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await _pump(tester);
      expect(_hairlineColor(tester), AppTokens.light.borderSubtle);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(RailDragHandle)));
      // Two bare frames: hover lands on the first, the animation's t=0 second.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      final mid = _hairlineColor(tester);
      expect(
        mid,
        isNot(AppTokens.light.borderSubtle),
        reason: 'the lerp has set off',
      );
      expect(
        mid,
        isNot(AppTokens.light.accentFill),
        reason: 'and has not already arrived',
      );

      await tester.pumpAndSettle();
      expect(_hairlineColor(tester), AppTokens.light.accentFill);
    },
  );

  testWidgets('reduce motion snaps straight to the hover colour, no travel', (
    tester,
  ) async {
    // Touch mode (the test default) suppresses FocusableActionDetector hover.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await _pump(tester, reduceMotion: true);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(RailDragHandle)));
    await tester.pump();

    expect(_hairlineColor(tester), AppTokens.light.accentFill);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
