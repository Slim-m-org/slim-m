// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Flutter folds an included `Tooltip`'s message into the accessible name
/// alongside the label, so a button whose tooltip only repeats its own
/// `semanticLabel` announced itself twice - "Note, Note". Most `AppIconButton`
/// callers pass the same string to both, so most of them did it.
///
/// It surfaced as a test failure rather than a bug report: the e2e harness
/// ranks click candidates by exact name match first, and a doubled name is
/// never an exact match, so a shorter unrelated node won the tie-break and the
/// wrong widget was clicked. That is a symptom; the doubled announcement is the
/// defect, and this pins both halves of the rule.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

/// The button's own semantics node - the one carrying the label, not the
/// wrapper above it.
SemanticsNode _button(WidgetTester tester) {
  final root = tester.getSemantics(find.byType(AppIconButton));
  SemanticsNode? labelled;
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) labelled ??= n;
    n.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return labelled ?? root;
}

void main() {
  testWidgets('a tooltip repeating the label is not announced a second time', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      AppIconButton(
        icon: Icons.note_add,
        semanticLabel: 'Note',
        tooltip: 'Note',
        onPressed: () {},
      ),
    );

    final node = _button(tester);
    expect(node.label, 'Note');
    expect(
      node.tooltip,
      isEmpty,
      reason:
          'the tooltip only repeats the label, so carrying it into semantics '
          'doubles what assistive tech announces - and on web it joins the '
          'accessible name, which is how this first showed up',
    );
    handle.dispose();
  });

  testWidgets(
      'a tooltip that says something else still reaches assistive '
      'tech', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      AppIconButton(
        icon: Icons.note_add,
        semanticLabel: 'Eraser',
        tooltip: "Can't draw right now",
        onPressed: () {},
      ),
    );

    final node = _button(tester);
    expect(node.label, 'Eraser');
    expect(
      node.tooltip,
      "Can't draw right now",
      reason:
          'a tooltip carrying what the label does not must survive - that is '
          'the whole reason the exclusion is conditional rather than blanket',
    );
    handle.dispose();
  });

  testWidgets('a caller can keep a different tooltip out of the name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      AppIconButton(
        icon: Icons.settings,
        semanticLabel: 'Personal settings',
        tooltip: 'Settings',
        excludeTooltipFromSemantics: true,
        onPressed: () {},
      ),
    );

    final node = _button(tester);
    expect(node.label, 'Personal settings');
    expect(
      node.tooltip,
      isEmpty,
      reason: 'the label already names the control, so the shorter tooltip '
          'would only be read out a second time',
    );
    handle.dispose();
  });
}
