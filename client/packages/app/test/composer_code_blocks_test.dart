// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's code action, the paste offer, and Enter inside a block,
/// driven through the real composer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/code_block_runner.dart';
import 'package:slimm_app/src/widgets/composer_code_picker.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

final _filterField = find.descendant(
  of: find.byType(CodeInsertPicker),
  matching: find.byType(TextField),
);

const _pastedRust = 'fn main() {\n    let x = 1;\n}';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpDesktop(WidgetTester tester, {Size? size}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size ?? const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        extraOverrides: [
          codeBlockRunnerProvider.overrideWith(
            (ref) async => const [
              api.CodeBlockRunner(
                moduleId: 'm',
                command: 'run',
                language: 'python',
              ),
            ],
          ),
        ],
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Insert code'));
    await tester.pumpAndSettle();
  }

  /// A paste lands its text and leaves the caret at the end of it.
  void paste(String before, String pasted) {
    controller.value = TextEditingValue(
      text: '$before$pasted',
      selection: TextSelection.collapsed(offset: before.length + pasted.length),
    );
  }

  group('the code action', () {
    testWidgets('picking a language inserts a fenced block, caret inside', (
      tester,
    ) async {
      await pumpDesktop(tester);
      await openPicker(tester);

      expect(find.text('Insert code'), findsWidgets);
      expect(find.text('Inline code'), findsOneWidget);
      await tester.tap(find.text('Python'));
      await tester.pumpAndSettle();

      expect(controller.text, '```python\n\n```');
      expect(controller.selection.baseOffset, '```python\n'.length);
    });

    testWidgets('a language a runner can run is marked as such', (
      tester,
    ) async {
      await pumpDesktop(tester);
      await openPicker(tester);

      final python = find.ancestor(
        of: find.text('Python'),
        matching: find.byType(AppListRow),
      );
      expect(
        find.descendant(of: python.first, matching: find.text('RUNS')),
        findsOneWidget,
      );
      final rust = find.ancestor(
        of: find.text('Rust'),
        matching: find.byType(AppListRow),
      );
      expect(
        find.descendant(of: rust.first, matching: find.text('RUNS')),
        findsNothing,
      );
    });

    testWidgets('typing filters, arrows move and Enter picks', (tester) async {
      await pumpDesktop(tester);
      await openPicker(tester);

      await tester.enterText(_filterField, 'scr');
      await tester.pump();
      expect(find.text('JavaScript'), findsOneWidget);
      expect(find.text('TypeScript'), findsOneWidget);
      expect(find.text('Python'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(controller.text, '```typescript\n\n```');
    });

    testWidgets('a name with no match still tags the block', (tester) async {
      await pumpDesktop(tester);
      await openPicker(tester);

      await tester.enterText(_filterField, 'Kotlin');
      await tester.pump();
      expect(find.textContaining('No match'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(controller.text, '```kotlin\n\n```');
    });

    testWidgets('inline code wraps a one-line selection in backticks', (
      tester,
    ) async {
      await pumpDesktop(tester);
      controller.value = const TextEditingValue(
        text: 'run make now',
        selection: TextSelection(baseOffset: 4, extentOffset: 8),
      );
      await openPicker(tester);
      await tester.tap(find.text('Inline code'));
      await tester.pumpAndSettle();

      expect(controller.text, 'run `make` now');
    });

    testWidgets('a multi-line selection offers no inline code and is fenced', (
      tester,
    ) async {
      await pumpDesktop(tester);
      controller.value = const TextEditingValue(
        text: 'a = 1\nb = 2',
        selection: TextSelection(baseOffset: 0, extentOffset: 11),
      );
      await openPicker(tester);

      expect(find.text('Inline code'), findsNothing);
      await tester.tap(find.text('Code block'));
      await tester.pumpAndSettle();

      expect(controller.text, '```\na = 1\nb = 2\n```');
    });

    testWidgets('at phone width the picker is a bottom sheet', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );
      await tester.tap(find.bySemanticsLabel('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Insert code'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('Code block'));
      await tester.pumpAndSettle();
      expect(controller.text, '```\n\n```');
      expect(tester.takeException(), isNull);
    });
  });

  group('pasting code', () {
    testWidgets('offers a block, and taking it fences the paste', (
      tester,
    ) async {
      await pumpDesktop(tester);
      paste('', 'look: ');
      paste('look: ', _pastedRust);
      await tester.pumpAndSettle();

      expect(find.text('That looks like Rust.'), findsOneWidget);
      await tester.tap(find.text('Format as code block'));
      await tester.pumpAndSettle();

      expect(controller.text, 'look: \n```rust\n$_pastedRust\n```');
      expect(find.text('Format as code block'), findsNothing);
    });

    testWidgets('keeping it as text, or typing on, drops the offer', (
      tester,
    ) async {
      await pumpDesktop(tester);
      paste('', _pastedRust);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Keep as text'));
      await tester.pumpAndSettle();
      expect(find.text('Format as code block'), findsNothing);
      expect(controller.text, _pastedRust);

      paste('$_pastedRust\n', _pastedRust);
      await tester.pumpAndSettle();
      expect(find.text('Format as code block'), findsOneWidget);
      paste(controller.text, '!');
      await tester.pumpAndSettle();
      expect(find.text('Format as code block'), findsNothing);
    });

    testWidgets(
      'prose, a restored draft, or a paste inside a block offer nothing',
      (tester) async {
        await pumpDesktop(tester);
        paste('', 'Hello there.\nSee you soon!');
        await tester.pumpAndSettle();
        expect(find.text('Format as code block'), findsNothing);

        controller.text = _pastedRust;
        await tester.pumpAndSettle();
        expect(find.text('Format as code block'), findsNothing);

        paste('', '```\n');
        paste('```\n', _pastedRust);
        await tester.pumpAndSettle();
        expect(find.text('Format as code block'), findsNothing);
      },
    );
  });

  group('Enter', () {
    testWidgets('inside an open block types a newline instead of sending', (
      tester,
    ) async {
      await pumpDesktop(tester);
      controller.value = const TextEditingValue(
        text: '```py\n  x = 1',
        selection: TextSelection.collapsed(offset: 13),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sends.count, 0);
      expect(controller.text, '```py\n  x = 1\n  ');
    });

    testWidgets('after the block closes, Enter sends again', (tester) async {
      await pumpDesktop(tester);
      controller.value = const TextEditingValue(
        text: '```\nx\n```',
        selection: TextSelection.collapsed(offset: 9),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sends.count, 1);
    });

    testWidgets('Ctrl+Enter sends from inside an open block', (tester) async {
      await pumpDesktop(tester);
      controller.value = const TextEditingValue(
        text: '```\nx',
        selection: TextSelection.collapsed(offset: 5),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(sends.count, 1);
    });
  });
}
