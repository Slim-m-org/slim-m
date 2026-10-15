// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What assistive tech and the keyboard read off the shared components
/// (issues 2023, 2027, 2031, 2032, 2036).
library;

import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('a plain icon button is not announced as a toggle',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
                icon: AppIcons.add, semanticLabel: 'Add', onPressed: () {}),
            AppIconButton(
              icon: AppIcons.micOff,
              semanticLabel: 'Mute',
              active: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Add'))
          .flagsCollection
          .isToggled,
      Tristate.none,
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Mute'))
          .flagsCollection
          .isToggled,
      Tristate.isTrue,
    );
    handle.dispose();
  });

  testWidgets('an avatar with a presence dot says the presence',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
        _harness(const AppAvatar(name: 'Ada', status: AppPresence.dnd)));
    expect(find.bySemanticsLabel('Ada, do not disturb'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a row nothing happens on is skipped by the keyboard',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppListRow(label: 'Just a label'),
            SizedBox(width: 200, child: TextField()),
          ],
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>(),
      isNotNull,
      reason: 'the first tab stop is the field, not the inert row',
    );
  });

  testWidgets('a disabled menu item is dimmed', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SizedBox(width: 240, child: AppMenuItem(label: 'Not now')),
      ),
    );
    final dimmed = tester.widgetList<Opacity>(
      find.descendant(
          of: find.byType(AppMenuItem), matching: find.byType(Opacity)),
    );
    expect(dimmed.any((o) => o.opacity < 1), isTrue);
  });

  testWidgets('a dismissable toast can be dismissed from its announced node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var dismissed = false;
    await tester.pumpWidget(
      _harness(AppToast(message: 'Saved', onDismiss: () => dismissed = true)),
    );
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('Saved')));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!
        .performAction(node.id, SemanticsAction.tap);
    expect(dismissed, isTrue);
    handle.dispose();
  });
}
