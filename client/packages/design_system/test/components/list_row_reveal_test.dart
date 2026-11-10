// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `AppListRow.revealTrailingExtraOnHover`: a hidden extra gives its width
/// back to the label, yet a keyboard can still reach it and a screen reader
/// still hears it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _label = 'a-channel-name-long-enough-to-be-cut-short-by-the-row';

Future<void> _pump(WidgetTester tester, {required bool withExtra}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: AppListRow(
                label: _label,
                touch: false,
                onTap: () {},
                revealTrailingExtraOnHover: true,
                trailingExtra: withExtra
                    ? AppIconButton(
                        icon: AppIcons.moreVertical,
                        semanticLabel: 'Manage it',
                        size: AppIconButtonSize.sm,
                        onPressed: () {},
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );

double _labelRight(WidgetTester tester) =>
    tester.getRect(find.text(_label)).right;

void main() {
  testWidgets('hidden, the extra takes no width from the label', (
    tester,
  ) async {
    await _pump(tester, withExtra: false);
    final bare = _labelRight(tester);
    await _pump(tester, withExtra: true);
    expect(_labelRight(tester), bare);
  });

  testWidgets('hidden, the extra is still announced', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, withExtra: true);
    final node = tester.getSemantics(find.bySemanticsLabel('Manage it'));
    expect(
      node.rect.isEmpty,
      isFalse,
      reason: 'an empty rect is dropped before it reaches a screen reader',
    );
    semantics.dispose();
  });

  testWidgets('a pointer over the row reveals the extra beside the label', (
    tester,
  ) async {
    await _pump(tester, withExtra: true);
    final hiddenRight = _labelRight(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text(_label)));
    await tester.pump(const Duration(milliseconds: 400));

    final extra = tester.getRect(find.byIcon(AppIcons.moreVertical));
    expect(_labelRight(tester), lessThan(hiddenRight));
    expect(_labelRight(tester), lessThanOrEqualTo(extra.left));

    await gesture.moveTo(const Offset(600, 400));
    await tester.pump();
    expect(_labelRight(tester), hiddenRight);
    await gesture.removePointer();
  });

  testWidgets('Tab reaches the hidden extra, which reveals and keeps focus', (
    tester,
  ) async {
    await _pump(tester, withExtra: true);
    final hiddenRight = _labelRight(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 400));

    final focused = FocusManager.instance.primaryFocus!.context!;
    final focusedRect = tester.getRect(find.byWidget(focused.widget));
    expect(
      focusedRect,
      tester.getRect(find.bySemanticsLabel('Manage it')),
      reason: 'the second Tab lands on the extra itself, not the row',
    );
    expect(_labelRight(tester), lessThan(hiddenRight));
  });
}
