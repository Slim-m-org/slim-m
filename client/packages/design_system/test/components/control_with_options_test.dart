// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caret only exists while there are options, a plain press keeps
/// its primary action, and adding the caret never shrinks a tap target below
/// `docs/design/desktop-vs-mobile.md` law 2 (44dp at touch density).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _caretLabel = 'Share options';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onOpenOptions,
  VoidCallback? onPressed,
  bool touch = false,
  bool destructive = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Center(
          child: AppControlWithOptions(
            touch: touch,
            destructive: destructive,
            optionsLabel: _caretLabel,
            onOpenOptions: onOpenOptions,
            child: AppIconButton(
              icon: AppIcons.screenShare,
              semanticLabel: 'Share',
              touch: touch,
              onPressed: onPressed ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
}

Finder get _caret => find.byIcon(AppIcons.chevronDown);

Size _caretHit(WidgetTester tester) =>
    tester.getSize(find.ancestor(of: _caret, matching: find.byType(InkWell)));

List<String> _recordHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? 'default');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

void main() {
  testWidgets('no caret and no extra width without options', (tester) async {
    await _pump(tester);
    expect(_caret, findsNothing);
    expect(
      tester.getSize(find.byType(AppControlWithOptions)),
      tester.getSize(find.byType(AppIconButton)),
    );
  });

  testWidgets('no long-press handler is attached without options', (
    tester,
  ) async {
    await _pump(tester);
    final handlers = tester
        .widgetList<GestureDetector>(
          find.descendant(
            of: find.byType(AppControlWithOptions),
            matching: find.byType(GestureDetector),
          ),
        )
        .where((g) => g.onLongPress != null || g.onSecondaryTapUp != null);
    expect(handlers, isEmpty);
  });

  testWidgets('a plain press keeps the primary action and opens nothing', (
    tester,
  ) async {
    var pressed = 0;
    var opened = 0;
    await _pump(
      tester,
      onPressed: () => pressed++,
      onOpenOptions: () => opened++,
    );
    await tester.tap(find.byType(AppIconButton));
    expect(pressed, 1);
    expect(opened, 0);
  });

  testWidgets('the caret opens the options without pressing the primary', (
    tester,
  ) async {
    var pressed = 0;
    var opened = 0;
    await _pump(
      tester,
      onPressed: () => pressed++,
      onOpenOptions: () => opened++,
    );
    expect(_caret, findsOneWidget);
    await tester.tap(_caret);
    expect(opened, 1);
    expect(pressed, 0);
  });

  testWidgets('a long-press opens the options with a selection haptic', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final haptics = _recordHaptics(tester);
    var pressed = 0;
    var opened = 0;
    await _pump(
      tester,
      onPressed: () => pressed++,
      onOpenOptions: () => opened++,
      touch: true,
    );
    await tester.longPress(find.byType(AppIconButton));
    expect(opened, 1);
    expect(pressed, 0);
    debugDefaultTargetPlatformOverride = null;
    expect(haptics, contains('HapticFeedbackType.selectionClick'));
  });

  testWidgets('the caret is a tab stop that Enter activates', (tester) async {
    var opened = 0;
    await _pump(tester, onOpenOptions: () => opened++);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the button and the caret each have a semantics label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onOpenOptions: () {});
    expect(find.bySemanticsLabel('Share'), findsOneWidget);
    expect(find.bySemanticsLabel(_caretLabel), findsOneWidget);
    handle.dispose();
  });

  for (final touch in [true, false]) {
    final minimum = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    testWidgets(
        'caret and primary keep a ${minimum}dp target '
        '(touch: $touch)', (tester) async {
      await _pump(tester, touch: touch);
      final primaryBefore = tester.getSize(find.byType(AppIconButton));
      await _pump(tester, touch: touch, onOpenOptions: () {});
      expect(tester.getSize(find.byType(AppIconButton)), primaryBefore);
      expect(primaryBefore.width, greaterThanOrEqualTo(minimum));
      expect(_caretHit(tester).width, greaterThanOrEqualTo(minimum));
      expect(_caretHit(tester).height, greaterThanOrEqualTo(minimum));
    });
  }

  testWidgets('the primary learns it is the joined half only with options', (
    tester,
  ) async {
    var joined = <bool>[];
    Future<void> pump(VoidCallback? open) => tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
                body: Center(
                    child: AppControlWithOptions(
              optionsLabel: _caretLabel,
              onOpenOptions: open,
              child: Builder(
                builder: (context) {
                  joined.add(AppControlWithOptions.joinedOf(context));
                  return const SizedBox(width: 44, height: 44);
                },
              ),
            ))),
          ),
        );
    await pump(null);
    expect(joined.last, isFalse);
    joined = [];
    await pump(() {});
    expect(joined.last, isTrue);
  });

  testWidgets('the caret touches the right edge of the primary', (
    tester,
  ) async {
    await pumpJoined(tester);
    final primary = tester.getRect(find.byKey(const Key('primary')));
    final caret = tester.getRect(
      find.ancestor(of: _caret, matching: find.byType(InkWell)),
    );
    expect(caret.left, primary.right);
  });

  Border caretBorder(WidgetTester tester) {
    final box = tester.widget<Container>(
      find
          .ancestor(
            of: find.byIcon(AppIcons.chevronDown),
            matching: find.byType(Container),
          )
          .first,
    );
    return (box.decoration! as BoxDecoration).border! as Border;
  }

  testWidgets('a destructive pair carries the danger outline around its caret',
      (
    tester,
  ) async {
    await _pump(tester, onOpenOptions: () {}, destructive: true);
    expect(caretBorder(tester).top.color, AppTokens.light.dangerBorder);
    expect(caretBorder(tester).right.color, AppTokens.light.dangerBorder);
  });

  testWidgets('a plain pair keeps the subtle caret outline', (tester) async {
    await _pump(tester, onOpenOptions: () {});
    expect(caretBorder(tester).top.color, AppTokens.light.borderSubtle);
  });
}

Future<void> pumpJoined(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Center(
            child: AppControlWithOptions(
              touch: true,
              optionsLabel: _caretLabel,
              onOpenOptions: () {},
              child: const SizedBox(key: Key('primary'), width: 44, height: 44),
            ),
          ),
        ),
      ),
    );
