// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash dissolves into the main window: the splash content fades out
/// when it is leaving, and the main window's content fades in once, unless
/// motion is reduced.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_entrance.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_design_system/design_system.dart';

double _opacityOf(WidgetTester tester, Finder child) {
  final fade = tester.widget<FadeTransition>(
    find.ancestor(of: child, matching: find.byType(FadeTransition)).first,
  );
  return fade.opacity.value;
}

void main() {
  testWidgets('the main window fades in once', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopEntrance(child: Text('content')),
      ),
    );
    expect(_opacityOf(tester, find.text('content')), 0);
    await tester.pump(AppMotion.slow ~/ 2);
    final mid = _opacityOf(tester, find.text('content'));
    expect(mid, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, find.text('content')), 1);
  });

  testWidgets('reduced motion shows the window at once', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: DesktopEntrance(child: Text('content')),
        ),
      ),
    );
    expect(_opacityOf(tester, find.text('content')), 1);
  });

  testWidgets('a leaving splash fades its content out', (tester) async {
    await tester.pumpWidget(const StartupApp());
    await tester.pump(const Duration(milliseconds: 400));
    AnimatedOpacity fade() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('slim-m'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(fade().opacity, 1);
    await tester.pumpWidget(const StartupApp(leaving: true));
    expect(fade().opacity, 0);
  });
}
