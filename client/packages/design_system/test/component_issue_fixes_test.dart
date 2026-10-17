// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The design system half of the October component audit (#2023-#2036):
/// each case reproduces the reported behaviour through the real widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(Widget child, {bool? touch}) {
  final body = Center(child: child);
  return MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: touch == null ? body : AppTouchTargets(enabled: touch, child: body),
    ),
  );
}

void main() {
  testWidgets('#2023 a plain icon button is not announced as a toggle', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close',
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.mic,
              semanticLabel: 'Mute',
              active: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Close')),
      isSemantics(isButton: true, hasToggledState: false),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Mute')),
      isSemantics(hasToggledState: true, isToggled: true),
    );
    handle.dispose();
  });

  testWidgets('#2025 a busy button keeps its width', (tester) async {
    Widget button({required bool busy}) =>
        _app(AppButton(label: 'Save changes', busy: busy, onPressed: () {}));
    await tester.pumpWidget(button(busy: false));
    final idle = tester.getSize(find.byType(AppButton));
    await tester.pumpWidget(button(busy: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(find.byType(AppButton)), idle);
  });

  testWidgets('#2027 an avatar with a presence dot says the presence', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const AppAvatar(name: 'Ada', status: AppPresence.away)),
    );
    expect(find.bySemanticsLabel('Ada, away'), findsOneWidget);
    await tester.pumpWidget(_app(const AppAvatar(name: 'Ada')));
    expect(find.bySemanticsLabel('Ada'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('#2029 a tap anywhere in the input box focuses the field', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SizedBox(
          width: 300,
          child: AppInput(size: AppInputSize.lg, placeholder: 'Name'),
        ),
      ),
    );
    final box = tester.getRect(find.byType(AppInput));
    await tester.tapAt(Offset(box.center.dx, box.top + 4));
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('#2032 a disabled menu item is dimmed', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppMenuItem(label: 'Disabled'),
            AppMenuItem(label: 'Enabled', onTap: () {}),
          ],
        ),
      ),
    );
    Color? ink(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(ink('Disabled'), AppTokens.dark.textDisabled);
    expect(ink('Enabled'), isNot(AppTokens.dark.textDisabled));
  });

  testWidgets('#2033 the slider meets the touch floor on touch',
      (tester) async {
    Widget slider({required bool touch}) => _app(
          SizedBox(width: 300, child: AppSlider(value: 50, onChanged: (_) {})),
          touch: touch,
        );
    await tester.pumpWidget(slider(touch: true));
    expect(tester.getSize(find.byType(Slider)).height, AppSizes.rowTouch);
    await tester.pumpWidget(slider(touch: false));
    expect(
      tester.getSize(find.byType(Slider)).height,
      lessThan(AppSizes.rowTouch),
    );
  });

  testWidgets('#2035 the code block fold toggle meets the touch floor', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 400,
          child: AppCodeBlock(
            lines: [
              for (var i = 0; i < 12; i++)
                AppCodeLine([AppCodeSpan('line $i')]),
            ],
            collapseAfterLines: 4,
          ),
        ),
        touch: true,
      ),
    );
    final toggle = find.ancestor(
      of: find.textContaining('more lines'),
      matching: find.byType(InkWell),
    );
    expect(
      tester.getSize(toggle.first).height,
      greaterThanOrEqualTo(AppSizes.rowTouch),
    );
  });

  testWidgets('#2036 a screen reader can dismiss a toast', (tester) async {
    final handle = tester.ensureSemantics();
    var dismissed = 0;
    await tester.pumpWidget(
      _app(AppToast(message: 'Saved', onDismiss: () => dismissed++)),
    );
    final toast = find.semantics.byLabel(RegExp('Saved'));
    expect(toast, findsOne);
    expect(toast.evaluate().single, isSemantics(hasTapAction: true));
    tester.semantics.tap(toast);
    expect(dismissed, 1);
    handle.dispose();
  });
}
