// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One tempo for the design system: the state changes that used to snap now
/// travel on [AppMotion]'s clocks, and each test here fails if its widget is
/// reverted to the bare repaint it once was.
///
/// Mid-flight assertions read the lerped value the implicit animation is
/// actually painting - the [Container] an [AnimatedContainer] builds each
/// frame, or the pair of children an [AnimatedSwitcher] keeps mounted while
/// cross-fading - rather than the widget's own target property, which reads
/// as already-arrived on the very first frame of the animation and would
/// pass with no animation at all.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Color? _paintedFill(WidgetTester tester, Finder scope) {
  final container = tester.widget<Container>(
    find.descendant(of: scope, matching: find.byType(Container)).first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('a presence flip cross-fades both shapes rather than snapping', (
    tester,
  ) async {
    var status = AppPresence.online;
    late StateSetter setStatus;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setStatus = setState;
          return AppStatusDot(status: status);
        },
      ),
    );

    setStatus(() => status = AppPresence.away);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final paints = find.descendant(
      of: find.byType(AppStatusDot),
      matching: find.byType(CustomPaint),
    );
    expect(
      paints,
      findsNWidgets(2),
      reason: 'mid-flip both shapes paint, cross-fading on AppMotion.fast',
    );
    await tester.pumpAndSettle();
    expect(paints, findsOneWidget);
  });

  testWidgets('an AppIconButton hover fill travels rather than snapping', (
    tester,
  ) async {
    // Touch mode (the test default) suppresses FocusableActionDetector hover.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await _pump(
      tester,
      AppIconButton(
        icon: Icons.add,
        semanticLabel: 'Add',
        onPressed: () {},
      ),
    );
    final scope = find.byType(AppIconButton);
    expect(_paintedFill(tester, scope), Colors.transparent);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(scope));
    // Two bare frames: hover lands on the first, the animation's t=0 second.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final target = AppTokens.light.surfaceRaised;
    final mid = _paintedFill(tester, scope);
    expect(mid, isNot(Colors.transparent), reason: 'the fill has set off');
    expect(mid, isNot(target), reason: 'and has not already arrived');
    await tester.pumpAndSettle();
    expect(_paintedFill(tester, scope), target);
  });

  testWidgets('an AppMenuItem press tints before release, and it travels', (
    tester,
  ) async {
    await _pump(tester, AppMenuItem(label: 'Item', onTap: () {}));
    final scope = find.byType(AppMenuItem);
    expect(_paintedFill(tester, scope), Colors.transparent);

    final gesture = await tester.startGesture(tester.getCenter(scope));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final target = AppTokens.light.textPrimary.withValues(alpha: 0.12);
    final mid = _paintedFill(tester, scope);
    expect(mid, isNot(Colors.transparent), reason: 'the tint has set off');
    expect(mid, isNot(target), reason: 'and has not already arrived');
    await tester.pumpAndSettle();
    expect(_paintedFill(tester, scope), target);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_paintedFill(tester, scope), Colors.transparent);
  });

  testWidgets('AppAsyncView settles resolved data in rather than popping', (
    tester,
  ) async {
    await _pump(
      tester,
      AppAsyncView<String>(
        value: const AppAsyncState(data: 'resolved'),
        data: (context, data) => Text(data),
        errorMessage: 'failed',
      ),
    );
    final veil = find
        .ancestor(of: find.text('resolved'), matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(veil).opacity, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(veil).opacity, 1);
  });

  List<double> dotOpacities(WidgetTester tester) => [
        for (final e in find
            .descendant(
              of: find.byType(AppTypingDots),
              matching: find.byType(Opacity),
            )
            .evaluate())
          (e.widget as Opacity).opacity,
      ];

  testWidgets('AppTypingDots pulse as a staggered wave', (tester) async {
    await _pump(tester, const AppTypingDots());
    await tester.pump(const Duration(milliseconds: 137));

    final first = dotOpacities(tester);
    expect(first, hasLength(3));
    expect(
      first.toSet(),
      hasLength(3),
      reason: 'the stagger keeps the three dots out of phase',
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(dotOpacities(tester), isNot(first), reason: 'and the wave moves');
  });

  testWidgets('AppRevealBand unfolds its band and retracts it again', (
    tester,
  ) async {
    Widget? band = const SizedBox(height: 40, width: 40);
    late StateSetter setBand;
    await _pump(
      tester,
      SizedBox(
        width: 200,
        child: StatefulBuilder(
          builder: (context, setState) {
            setBand = setState;
            return AppRevealBand(child: band);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = tester.getSize(find.byType(AppRevealBand)).height;
    expect(open, 40);

    setBand(() => band = null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final mid = tester.getSize(find.byType(AppRevealBand)).height;
    expect(mid, greaterThan(0), reason: 'the band retracts over a beat');
    expect(mid, lessThan(open), reason: 'rather than holding then popping');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppRevealBand)).height, 0);
  });

  testWidgets('AppTypingDots hold still under reduce motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Center(child: AppTypingDots())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(dotOpacities(tester), everyElement(1.0));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
