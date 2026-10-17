// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [MessageJumpHighlight] on its own: the flash it shows on arrival, and the
/// reduce-motion rule that it must be held flat and removed rather than
/// animated.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';
import 'package:slimm_design_system/design_system.dart';

const _child = Text('target message');

Future<void> _pump(
  WidgetTester tester, {
  required bool reduceMotion,
  required VoidCallback onArrived,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ListView(
            children: [
              MessageJumpHighlight(onArrived: onArrived, child: _child),
            ],
          ),
        ),
      ),
    ),
  );
}

Color? _tint(WidgetTester tester) {
  final decoration = tester
      .widget<AnimatedContainer>(find.byType(AnimatedContainer))
      .decoration;
  return (decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('lands lit, then eases back out under full motion', (
    tester,
  ) async {
    var arrived = false;
    await _pump(tester, reduceMotion: false, onArrived: () => arrived = true);
    await tester.pump();

    expect(
      _tint(tester),
      isNot(Colors.transparent),
      reason: 'the arrival must be visibly marked, not silent',
    );
    expect(find.text('target message'), findsOneWidget);
    expect(arrived, isFalse, reason: 'still lit; nothing has been handled yet');

    // Past the hold, still fading: not yet told to the controller as handled.
    await tester.pump(const Duration(milliseconds: 900));
    expect(arrived, isFalse);

    // Past hold and fade both.
    await tester.pump(const Duration(milliseconds: 2100));
    expect(_tint(tester), Colors.transparent);
    expect(
      arrived,
      isTrue,
      reason: 'only handed back once the fade has actually finished playing',
    );
  });

  testWidgets('is held flat and removed, never eased, under reduce motion', (
    tester,
  ) async {
    var arrived = false;
    await _pump(tester, reduceMotion: true, onArrived: () => arrived = true);
    await tester.pump();

    expect(_tint(tester), isNot(Colors.transparent));

    // Short of the reduced hold: still flat, nothing has changed yet.
    await tester.pump(const Duration(milliseconds: 400));
    expect(_tint(tester), isNot(Colors.transparent));
    expect(arrived, isFalse);

    // Past the reduced hold: removed outright, with no fading frame in between since the container's own duration is zero here.
    await tester.pump(const Duration(milliseconds: 200));
    expect(_tint(tester), Colors.transparent);
    expect(arrived, isTrue);
  });
}
