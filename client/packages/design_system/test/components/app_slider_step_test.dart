// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The key step is the step for every way of nudging a slider.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<List<double>> _pump(
  WidgetTester tester,
  List<double> changes,
  List<double> commits,
) async {
  var value = 100.0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 300,
            child: AppSlider(
              value: value,
              min: 0,
              max: 200,
              keyStep: 5,
              autofocus: true,
              onChanged: (v) => setState(() {
                value = v;
                changes.add(v);
              }),
              onChangeEnd: commits.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return changes;
}

void main() {
  testWidgets('a screen reader increase moves by the key step', (tester) async {
    final handle = tester.ensureSemantics();
    final changes = <double>[];
    await _pump(tester, changes, []);

    tester.semantics
        .increase(find.semantics.byAction(SemanticsAction.increase));
    await tester.pump();
    tester.semantics
        .decrease(find.semantics.byAction(SemanticsAction.decrease));
    await tester.pump();
    tester.semantics
        .decrease(find.semantics.byAction(SemanticsAction.decrease));
    await tester.pump();

    expect(changes, [105, 100, 95]);
    handle.dispose();
  });

  testWidgets('a drag is not snapped to the key step', (tester) async {
    final changes = <double>[];
    await _pump(tester, changes, []);

    await tester.drag(find.byType(Slider), const Offset(3, 0));
    await tester.pump();

    expect(changes, isNotEmpty);
    expect(changes.any((v) => v % 5 != 0), isTrue, reason: '$changes');
  });

  testWidgets('a held arrow key commits once, on release', (tester) async {
    final changes = <double>[];
    final commits = <double>[];
    await _pump(tester, changes, commits);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes, [105, 110, 115]);
    expect(commits, [105], reason: 'only the first press commits at once');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(commits, [105, 115]);
  });

  testWidgets('a single press commits immediately and not again on release',
      (tester) async {
    final commits = <double>[];
    await _pump(tester, [], commits);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);

    expect(commits, [95]);
  });
}
