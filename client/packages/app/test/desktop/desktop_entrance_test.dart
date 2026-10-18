// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash dissolves into the main window: the splash content fades out
/// when it is leaving, and the main window's content fades in once while the
/// startup mark glides into the rail corner, unless motion is reduced.
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
  setUp(resetDesktopEntranceForTest);

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

  testWidgets('the startup mark glides from the middle into the rail '
      'header corner, below the title bar, and is gone afterwards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: DesktopEntrance(topInset: 40, child: SizedBox.expand()),
      ),
    );
    await tester.pump();
    final first = tester.getRect(find.byType(AppBrandMark));
    expect(first.center.dx, closeTo(640, 1));
    expect(first.center.dy, closeTo(360, 1));

    await tester.pump(kDesktopEntranceDuration * 0.8);
    final landed = tester.getRect(find.byType(AppBrandMark));
    expect(landed.left, closeTo(16, 1));
    expect(landed.top, closeTo(56, 1));
    expect(landed.width, closeTo(20, 1));

    await tester.pumpAndSettle();
    expect(find.byType(AppBrandMark), findsNothing);
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
