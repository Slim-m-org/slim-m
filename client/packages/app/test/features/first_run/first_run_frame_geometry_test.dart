// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The setup card keeps one height across steps and its footer buttons share
/// the body's left and right edges.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_frame.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _frame(double bodyHeight, {double? cardHeight}) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(
    body: FirstRunFrame(
      step: 1,
      stepCount: 4,
      title: 'Voice defaults',
      cardHeight: cardHeight,
      onBack: () {},
      onContinue: () {},
      onSkip: () {},
      body: SizedBox(key: const Key('body'), height: bodyHeight),
    ),
  ),
);

final _card = find.byWidgetPredicate(
  (w) =>
      w is Material &&
      w.shape is RoundedRectangleBorder &&
      w.clipBehavior == Clip.antiAlias,
);

Rect _button(WidgetTester tester, String label) => tester.getRect(
  find
      .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is AppButton),
      )
      .first,
);

void main() {
  void useDesktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a pinned card height is the same for a short and a tall step', (
    tester,
  ) async {
    useDesktop(tester);
    await tester.pumpWidget(_frame(80, cardHeight: 600));
    final short = tester.getSize(_card).height;
    await tester.pumpWidget(_frame(500, cardHeight: 600));
    final tall = tester.getSize(_card).height;
    expect(short, 600);
    expect(tall, short);
  });

  testWidgets('footer buttons and Skip setup sit on the body edges', (
    tester,
  ) async {
    useDesktop(tester);
    await tester.pumpWidget(_frame(80, cardHeight: 600));
    final body = tester.getRect(find.text('Voice defaults'));
    expect(_button(tester, 'Back').left, body.left);
    final card = tester.getRect(_card);
    expect(_button(tester, 'Continue').right, card.right - AppSpacing.s24);
    final skip = tester.getRect(find.text('Skip setup'));
    expect(skip.right, closeTo(card.right - AppSpacing.s24, 0.5));
  });
}
