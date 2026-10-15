// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What assistive tech and the keyboard read off the shared components
/// (issues 2023, 2027, 2031, 2032, 2036).
library;

import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('an avatar with a presence dot says the presence',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
        _harness(const AppAvatar(name: 'Ada', status: AppPresence.dnd)));
    expect(find.bySemanticsLabel('Ada, do not disturb'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an inert row still lets its own control be reached and tapped',
      (tester) async {
    final handle = tester.ensureSemantics();
    var removed = 0;
    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: 320,
          child: AppListRow(
            label: 'Maya',
            trailing: AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Remove',
              onPressed: () => removed++,
            ),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Remove'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Remove'));
    expect(removed, 1);

    var reachedButton = false;
    for (var i = 0; i < 3 && !reachedButton; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      reachedButton =
          focused?.findAncestorWidgetOfExactType<AppIconButton>() != null;
    }
    expect(reachedButton, isTrue,
        reason: 'the row is skipped, its button is the stop');
    handle.dispose();
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
    tester.semantics.tap(find.semantics.byLabel(RegExp('Saved')));
    expect(dismissed, isTrue);
    handle.dispose();
  });

  testWidgets('a button keeps its width while busy (issue 2025)',
      (tester) async {
    Future<double> widthWhen({required bool busy}) async {
      await tester.pumpWidget(
        _harness(
            AppButton(label: 'Save changes', busy: busy, onPressed: () {})),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.getSize(find.byType(AppButton)).width;
    }

    final idle = await widthWhen(busy: false);
    expect(await widthWhen(busy: true), idle);
  });

  testWidgets('a slider is a full touch target at touch density (issue 2033)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        AppTouchTargets(
          enabled: true,
          child: SizedBox(
              width: 240, child: AppSlider(value: 40, onChanged: (_) {})),
        ),
      ),
    );
    expect(
        tester.getSize(find.byType(Slider)).height, greaterThanOrEqualTo(44));
  });

  testWidgets('a tap in the input padding focuses it (issue 2029)',
      (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _harness(SizedBox(width: 240, child: AppInput(focusNode: focus))),
    );
    final box = tester.getRect(find.byType(AppInput));
    await tester.tapAt(box.topLeft + const Offset(4, 4));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
  });
}
